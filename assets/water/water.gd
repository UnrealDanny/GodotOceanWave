@tool
extends MeshInstance3D
## Handles updating the displacement/normal maps for the water material as well as
## managing wave generation pipelines.

const WATER_MAT := preload('res://assets/water/mat_water.tres')
const SPRAY_MAT := preload('res://assets/water/mat_spray.tres')
const WATER_MESH_HIGH8K := preload('res://assets/water/clipmap_high_8k.obj')
const WATER_MESH_HIGH := preload('res://assets/water/clipmap_high.obj')
const WATER_MESH_LOW := preload('res://assets/water/clipmap_low.obj')

enum MeshQuality { LOW, HIGH, HIGH8K }

@export_group('Wave Parameters')
@export_color_no_alpha var water_color : Color = Color(0.1, 0.15, 0.18) :
	set(value): water_color = value; RenderingServer.global_shader_parameter_set(&'water_color', water_color.srgb_to_linear())

@export_color_no_alpha var foam_color : Color = Color(0.73, 0.67, 0.62) :
	set(value): foam_color = value; RenderingServer.global_shader_parameter_set(&'foam_color', foam_color.srgb_to_linear())

@export var parameters : Array[WaveCascadeParameters] :
	set(value):
		var new_size := value.size()
		for i in range(new_size):
			if not value[i]: value[i] = WaveCascadeParameters.new()
			if not value[i].is_connected(&'scale_changed', _update_scales_uniform):
				value[i].scale_changed.connect(_update_scales_uniform)
			value[i].spectrum_seed = Vector2i(rng.randi_range(-10000, 10000), rng.randi_range(-10000, 10000))
			value[i].time = 120.0 + PI * i 
		parameters = value
		_setup_wave_generator()
		_update_scales_uniform()
		_setup_cpu_displacement_textures()

@export_group('Performance Parameters')

@export_enum('128x128:128', '256x256:256', '512x512:512', '1024x1024:1024') var map_size := 1024 :
	set(value):
		map_size = value
		_setup_wave_generator()

@export var mesh_quality := MeshQuality.HIGH :
	set(value):
		mesh_quality = value
		if mesh_quality == MeshQuality.LOW:
			mesh = WATER_MESH_LOW
		if mesh_quality == MeshQuality.HIGH:
			mesh = WATER_MESH_HIGH
		if mesh_quality == MeshQuality.HIGH8K:
			mesh = WATER_MESH_HIGH8K

@export_range(0, 60) var updates_per_second := 50.0 :
	set(value):
		next_update_time = next_update_time - (1.0 / (updates_per_second + 1e-10) - 1.0 / (value + 1e-10))
		updates_per_second = value

@export var bake_waves: bool = false :
	set(value):
		if value:
			bake_waves_to_res() # Changed name here
		bake_waves = false
		
		
var wave_generator : WaveGenerator :
	set(value):
		if wave_generator: wave_generator.queue_free()
		wave_generator = value
		add_child(wave_generator)

var rng = RandomNumberGenerator.new()
var time := 0.0
var next_update_time := 0.0

var displacement_maps := Texture2DArrayRD.new()
var normal_maps := Texture2DArrayRD.new()

var update_textures: bool = true
var just_calculated_water: bool = false

# CPU readback variables
var mutex: Mutex = Mutex.new()
var _cpu_displacement_textures : Dictionary = {} 
var _displacement_textures_total_update_interval: float = 1.0 / 120.0
var _displacement_textures_update_time: float = 0.0
var _texture_loading_index: int = 0
var _is_reading_back: bool = false # Replaces the WorkerThreadPool ID

func _init() -> void:
	rng.set_seed(1234)

func _ready() -> void:
	# Tell the CPU not to cull the mesh unless it is safely far off-screen
	extra_cull_margin = 150.0 
	
	RenderingServer.global_shader_parameter_set(&'water_color', water_color.srgb_to_linear())
	RenderingServer.global_shader_parameter_set(&'foam_color', foam_color.srgb_to_linear())

func _process(delta : float) -> void:
	just_calculated_water = false
	if updates_per_second == 0.0 or time >= next_update_time:
		var target_update_delta := 1.0 / (updates_per_second + 1e-10)
		var update_delta := delta if updates_per_second == 0.0 else target_update_delta + (time - next_update_time)
		next_update_time = time + target_update_delta
		
		_update_water(update_delta)
		
		if update_textures:
			_manage_cpu_displacement_textures_updates(delta)
		just_calculated_water = true
	time += delta

func _setup_wave_generator() -> void:
	if parameters.size() <= 0: return
	for param in parameters:
		param.should_generate_spectrum = true

	wave_generator = WaveGenerator.new()
	wave_generator.map_size = map_size
	wave_generator.init_gpu(maxi(2, parameters.size())) 

	displacement_maps.texture_rd_rid = RID()
	normal_maps.texture_rd_rid = RID()
	displacement_maps.texture_rd_rid = wave_generator.descriptors[&'displacement_map'].rid
	normal_maps.texture_rd_rid = wave_generator.descriptors[&'normal_map'].rid

	RenderingServer.global_shader_parameter_set(&'num_cascades', parameters.size())
	RenderingServer.global_shader_parameter_set(&'displacements', displacement_maps)
	RenderingServer.global_shader_parameter_set(&'normals', normal_maps)

func _update_scales_uniform() -> void:
	var map_scales : PackedVector4Array; map_scales.resize(parameters.size())
	for i in parameters.size():
		var params := parameters[i]
		var uv_scale := Vector2.ONE / params.tile_length
		map_scales[i] = Vector4(uv_scale.x, uv_scale.y, params.displacement_scale, params.normal_scale)
	
	WATER_MAT.set_shader_parameter(&'map_scales', map_scales)
	SPRAY_MAT.set_shader_parameter(&'map_scales', map_scales)

func _update_water(delta : float) -> void:
	if wave_generator == null: _setup_wave_generator()
	wave_generator.update(delta, parameters)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		displacement_maps.texture_rd_rid = RID()
		normal_maps.texture_rd_rid = RID()

# =============================================================================
#  displacement textures loading from gpu (Render Thread Safe)
# =============================================================================

func _manage_cpu_displacement_textures_updates(delta: float) -> void:
	if _cpu_displacement_textures.size() < 1:
		return

	# Ensure we don't queue another readback if the render thread is still processing the last one
	if _is_reading_back:
		return

	var time_per_texture: float = _displacement_textures_total_update_interval / float(_cpu_displacement_textures.size())
	var _cpu_displacement_textures_indeces = _cpu_displacement_textures.keys()
	_cpu_displacement_textures_indeces.sort()
	
	if _displacement_textures_update_time > time_per_texture:
		_texture_loading_index += 1
		if _texture_loading_index >= _cpu_displacement_textures.size():
			_texture_loading_index = 0
			
		var target_idx = _cpu_displacement_textures_indeces[_texture_loading_index]
		
		_is_reading_back = true
		# Dispatch directly to the engine's Render Thread to satisfy the RenderingDevice requirement
		RenderingServer.call_on_render_thread(_do_texture_readback.bind(target_idx))
		
		_displacement_textures_update_time = 0.0
	_displacement_textures_update_time += delta

func _do_texture_readback(idx: int) -> void:
	var rid_displacement_map = wave_generator.descriptors[&'displacement_map'].rid
	var device: RenderingDevice = RenderingServer.get_rendering_device()
	
	# This now runs natively on the Render Thread, satisfying Vulkan!
	var tex = device.texture_get_data(rid_displacement_map, idx) 
	var img = Image.create_from_data(wave_generator.map_size, wave_generator.map_size, false, Image.FORMAT_RGBAH, tex)
	
	mutex.lock()
	_cpu_displacement_textures[idx] = img
	_is_reading_back = false
	mutex.unlock()

func _setup_cpu_displacement_textures() -> void:
	var _actually_used_textures_idx: Array = []
	for i in range(parameters.size()):
		var cascade = parameters[i]
		if cascade.displacement_scale > 0.001:
			_actually_used_textures_idx.append(i)
	
	# We must also push the initial setup to the Render Thread!
	RenderingServer.call_on_render_thread(_do_initial_texture_readback.bind(_actually_used_textures_idx))

func _do_initial_texture_readback(used_indices: Array) -> void:
	if not wave_generator or not wave_generator.descriptors.has(&'displacement_map'): return
	
	var rid_displacement_map = wave_generator.descriptors[&'displacement_map'].rid
	var device: RenderingDevice = RenderingServer.get_rendering_device()

	mutex.lock()
	for i in used_indices:
		var tex = device.texture_get_data(rid_displacement_map, i) 
		var img: Image = Image.create_from_data(wave_generator.map_size, wave_generator.map_size, false, Image.FORMAT_RGBAH, tex)
		_cpu_displacement_textures[i] = img
	mutex.unlock()

func _world_to_uv(W: Vector2, tile_length: Vector2) -> Vector2:
	return Vector2(
		(W[0] - tile_length.x * floor(W[0] / tile_length.x)) / tile_length.x,
		(W[1] - tile_length.y * floor(W[1] / tile_length.y)) / tile_length.y)

func get_height(world_pos: Vector3, steps: int = 3) -> float:
	var world_pos_xz = Vector2(world_pos.x, world_pos.z)
	var summed_height: float = 0.0
	
	mutex.lock() # Lock while reading to prevent the thread pool from writing at the same time
	for cascade_index in _cpu_displacement_textures.keys():
		var displacement_scale: float = parameters[cascade_index].displacement_scale
		var tile_length: Vector2 = parameters[cascade_index].tile_length
		var x: Vector2 = world_pos_xz
		var y: Vector2 = Vector2.ZERO
		var y_raw: Color = Color.BLACK
		
		for i in range(steps):
			# Calculate the raw floating point pixel coordinate
			var img_v = _world_to_uv(x, tile_length) * float(map_size)
			
			# THE FIX: Cast to integer and use wrapi() to safely loop coordinates.
			# wrapi(1024, 0, 1024) will safely return 0.
			var pixel_x := wrapi(int(img_v.x), 0, map_size)
			var pixel_y := wrapi(int(img_v.y), 0, map_size)
			
			# Read safely using integer coordinates
			y_raw = _cpu_displacement_textures[cascade_index].get_pixel(pixel_x, pixel_y)
			y = Vector2(y_raw.r, y_raw.b)
			x = world_pos_xz - y
			
		summed_height += y_raw.g * displacement_scale
	mutex.unlock()
	
	return summed_height

func bake_waves_to_res() -> void:
	print("Starting Ocean Bake...")
	var frames_to_bake := 64
	var time_step := 0.05 
	var cascade_to_bake := 0 
	
	# 1. Calculate the exact duration of the exported animation (64 * 0.05 = 3.2 seconds)
	var total_bake_duration := float(frames_to_bake) * time_step
	
	# 2. Force the simulation into a mathematically perfect loop
	for p in parameters:
		p.loop_period = total_bake_duration
		p.time = 0.0 # Reset time to 0 so the loop starts cleanly
		p.should_generate_spectrum = true # Force the GPU to rebuild the FFT!
	
	# Force a frame update so the GPU catches the reset before we start recording
	_update_water(0.0)
	RenderingServer.force_sync()
	
	var baked_images : Array[Image] = []
	
	for frame in range(frames_to_bake):
		_update_water(time_step)
		RenderingServer.force_sync() 
		
		var rid_displacement_map = wave_generator.descriptors[&'displacement_map'].rid
		var device: RenderingDevice = RenderingServer.get_rendering_device()
		var tex = device.texture_get_data(rid_displacement_map, cascade_to_bake) 
		
		var img := Image.create_from_data(wave_generator.map_size, wave_generator.map_size, false, Image.FORMAT_RGBAH, tex)
		baked_images.append(img)
		print("Baked frame %d/%d" % [frame + 1, frames_to_bake])
		
	print("Packaging frames into Texture2DArray...")
	
	# 3. Release the waves back to normal, chaotic simulation after the bake is done
	for p in parameters:
		p.loop_period = 0.0
		p.should_generate_spectrum = true
	
	var texture_array := Texture2DArray.new()
	var err := texture_array.create_from_images(baked_images)
	
	if err == OK:
		var save_path := "res://baked_waves/baked_ocean_array.res"
		ResourceSaver.save(texture_array, save_path)
		print("Bake Complete! Saved directly to: ", save_path)
	else:
		print("Failed to create Texture2DArray. Error code: ", err)
