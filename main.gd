@tool
extends Node3D

var clipmap_tile_size := 1.0 # Not the smallest tile size, but one that reduces the amount of vertex jitter.
var previous_tile := Vector3i.MAX
var should_render_imgui := not Engine.is_editor_hint()
var _default_cache : Dictionary = {}

@onready var viewport : Variant = Engine.get_singleton(&'EditorInterface').get_editor_viewport_3d(0) if Engine.is_editor_hint() else get_viewport()
@onready var camera : Variant = viewport.get_camera_3d()
@onready var water := $Water

# References to various parameters (for imgui) - CHANGED to strict typed arrays
@onready var _camera_fov : Array[float] = [camera.fov]
@onready var _updates_per_second : Array[float] = [water.updates_per_second]
@onready var _water_color : Array[float] = [water.water_color.r, water.water_color.g, water.water_color.b]
@onready var _foam_color : Array[float] = [water.foam_color.r, water.foam_color.g, water.foam_color.b]
@onready var _is_sea_spray_visible : Array[bool] = [true]
@onready var _update_textures : Array[bool] = [true]

# --- NEW: Subsurface Glow UI Variables ---
@onready var _crest_color : Array[float] = [0.0, 0.65, 0.85]
@onready var _crest_glow_intensity : Array[float] = [0.8]
@onready var _aerated_foam_glow : Array[float] = [0.5]

func _ready() -> void:
	if Engine.is_editor_hint(): return
	
	# 1. Cache the base scalars and colors
	_default_cache["fov"] = camera.fov
	_default_cache["map_size"] = water.map_size
	_default_cache["mesh_quality"] = water.mesh_quality
	_default_cache["clipmap_tile"] = clipmap_tile_size
	_default_cache["updates"] = water.updates_per_second
	_default_cache["water_color"] = water.water_color
	_default_cache["foam_color"] = water.foam_color
	_default_cache["sea_spray"] = $Water/WaterSprayEmitter.visible
	_default_cache["update_tex"] = water.update_textures
	
	# 2. Cache Shader properties
	_default_cache["crest_color"] = Color(_crest_color[0], _crest_color[1], _crest_color[2])
	_default_cache["crest_glow"] = _crest_glow_intensity[0]
	_default_cache["aerated_glow"] = _aerated_foam_glow[0]
	
	# 3. Deep copy the cascade parameters (so we save the original math)
	var default_cascades : Array[WaveCascadeParameters] = []
	for p in water.parameters:
		default_cascades.append(p.duplicate(true))
	_default_cache["cascades"] = default_cascades
	
func _init() -> void:
	if Engine.is_editor_hint(): return
	if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		
	# CHANGED: Explicitly cast the Vector2 math back to Vector2i to prevent strict-type crashes
	var screen_size := Vector2(DisplayServer.screen_get_size())
	DisplayServer.window_set_size(Vector2i(screen_size * 0.75))
	DisplayServer.window_set_position(Vector2i(screen_size * 0.25 / 2.0))

func _process(_delta : float) -> void:
	if not Engine.is_editor_hint():
		if should_render_imgui:
			_render_imgui()
		camera.enable_camera_movement = not (ImGui.IsWindowHovered(ImGui.HoveredFlags_AnyWindow) or ImGui.IsAnyItemActive())

func _physics_process(_delta: float) -> void:
	# Shift water mesh whenever player moves into a new tile.
	var tile := (Vector3(camera.global_position.x, 0.0, camera.global_position.z) / clipmap_tile_size).ceil()
	if not tile.is_equal_approx(previous_tile):
		water.global_position = tile * clipmap_tile_size
		previous_tile = tile

	# Vary audio samples based on total wind speed across all cascades.
	var total_wind_speed := 0.0
	for params in water.parameters:
		total_wind_speed += params.wind_speed
	$OceanAudioPlayer.volume_db = lerpf(-30.0, 15.0, minf(total_wind_speed/15.0, 1.0))
	$WindAudioPlayer.volume_db = lerpf(5.0, -30.0, minf(total_wind_speed/15.0, 1.0))

func _input(event: InputEvent) -> void:
	if event.is_action_pressed(&'toggle_imgui'):
		should_render_imgui = not should_render_imgui
	elif event.is_action_pressed(&'toggle_fullscreen'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED else DisplayServer.WINDOW_MODE_WINDOWED)
	elif event.is_action_pressed(&'ui_cancel'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

func imgui_text_tooltip(title : String, tooltip : String) -> void:
	ImGui.Text(title)
	if ImGui.IsItemHovered() and not tooltip.is_empty(): 
		ImGui.SetTooltip(tooltip)

func _render_imgui() -> void:
	var fps := Engine.get_frames_per_second()
	var mesh_quality_keys : Array = water.MeshQuality.keys()

	ImGui.Begin(' ', [], ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoMove)
	ImGui.SetWindowPos(Vector2(20.0, 20.0))
	ImGui.SeparatorText('OceanWaves')
	ImGui.Text('FPS:                %d (%s)' % [fps, '%.2fms' % (1.0 / fps*1e3)])
	
	ImGui.Text('Enable Sea Spray:  ')
	ImGui.SameLine()
	if ImGui.Checkbox('##sea_spray_checkbox', _is_sea_spray_visible): 
		$Water/WaterSprayEmitter.visible = _is_sea_spray_visible[0]
		
	imgui_text_tooltip('Wave Resolution:   ', 'The resolution of the displacement/normal maps used for each wave cascade.\nThis is also the FFT input size.')
	ImGui.SameLine()
	
	if ImGui.BeginCombo('##resolution', '%dx%d' % [water.map_size, water.map_size]):
		for resolution in [128, 256, 512, 1024]:
			if ImGui.Selectable('%dx%d' % [resolution, resolution]):
				water.map_size = resolution
		ImGui.EndCombo()
		
	ImGui.Text('Wave Mesh Quality: ')
	ImGui.SameLine()
	
	# CHANGED: Replaced len() with .size()
	if ImGui.BeginCombo('##mesh_quality', '%s' % mesh_quality_keys[water.mesh_quality].capitalize()):
		for mesh_quality in water.MeshQuality.size():
			if ImGui.Selectable('%s' % mesh_quality_keys[mesh_quality].capitalize()):
				water.mesh_quality = mesh_quality
				clipmap_tile_size = 1.0 if mesh_quality == water.MeshQuality.HIGH else 4.0
		ImGui.EndCombo()
		
	imgui_text_tooltip('Updates per Second:', 'Denotes how many times wave spectrums will be updated per second.\n(0 is uncapped)')
	ImGui.SameLine()
	if ImGui.SliderFloat('##update_rate', _updates_per_second, 0.0, 60.0): 
		water.updates_per_second = _updates_per_second[0]
		
	ImGui.Text('Get displacement textures from GPU:  ')
	ImGui.SameLine()
	if ImGui.Checkbox('##update_textures_checkbox', _update_textures): 
		water.update_textures = _update_textures[0]
	
	ImGui.Text('Water Color:       ')
	ImGui.SameLine()
	if ImGui.ColorButtonEx('##water_color_button', water.water_color, ImGui.ColorEditFlags_Float, Vector2(ImGui.GetColumnWidth(), ImGui.GetFrameHeight())): 
		ImGui.OpenPopup('water_color_picker')
		
	if ImGui.BeginPopup('water_color_picker'):
		if ImGui.ColorPicker3('##water_color_picker', _water_color, ImGui.ColorEditFlags_Float | ImGui.ColorEditFlags_NoSidePreview | ImGui.ColorEditFlags_DisplayRGB | ImGui.ColorEditFlags_DisplayHex):
			water.water_color = Color(_water_color[0], _water_color[1], _water_color[2])
		ImGui.EndPopup()
		
	ImGui.Text('Foam Color:        ')
	ImGui.SameLine()
	if ImGui.ColorButtonEx('##foam_color_button', water.foam_color, ImGui.ColorEditFlags_Float, Vector2(ImGui.GetColumnWidth(), ImGui.GetFrameHeight())): 
		ImGui.OpenPopup('foam_color_picker')
		
	if ImGui.BeginPopup('foam_color_picker'):
		if ImGui.ColorPicker3('##foam_color_picker', _foam_color, ImGui.ColorEditFlags_Float | ImGui.ColorEditFlags_NoSidePreview | ImGui.ColorEditFlags_DisplayRGB | ImGui.ColorEditFlags_DisplayHex):
			water.foam_color = Color(_foam_color[0], _foam_color[1], _foam_color[2])
		ImGui.EndPopup()
	
	if ImGui.BeginPopup('foam_color_picker'):
		if ImGui.ColorPicker3('##foam_color_picker', _foam_color, ImGui.ColorEditFlags_Float | ImGui.ColorEditFlags_NoSidePreview | ImGui.ColorEditFlags_DisplayRGB | ImGui.ColorEditFlags_DisplayHex):
			water.foam_color = Color(_foam_color[0], _foam_color[1], _foam_color[2])
		ImGui.EndPopup()

	# --- NEW: Subsurface Glow ImGui Controls ---
	ImGui.SeparatorText('Subsurface Glow')
	ImGui.Text('Crest Color:       ')
	ImGui.SameLine()
	
	var current_crest_color := Color(_crest_color[0], _crest_color[1], _crest_color[2])
	if ImGui.ColorButtonEx('##crest_color_button', current_crest_color, ImGui.ColorEditFlags_Float, Vector2(ImGui.GetColumnWidth(), ImGui.GetFrameHeight())): 
		ImGui.OpenPopup('crest_color_picker')
		
	if ImGui.BeginPopup('crest_color_picker'):
		if ImGui.ColorPicker3('##crest_color_picker', _crest_color, ImGui.ColorEditFlags_Float | ImGui.ColorEditFlags_NoSidePreview | ImGui.ColorEditFlags_DisplayRGB | ImGui.ColorEditFlags_DisplayHex):
			var new_color := Color(_crest_color[0], _crest_color[1], _crest_color[2])
			water.get_active_material(0).set_shader_parameter("crest_color", new_color)
		ImGui.EndPopup()
		
	imgui_text_tooltip('Crest Glow:        ', 'Glow intensity on the high wave peaks.')
	ImGui.SameLine()
	if ImGui.SliderFloat('##crest_glow', _crest_glow_intensity, 0.0, 2.0): 
		water.get_active_material(0).set_shader_parameter("crest_glow_intensity", _crest_glow_intensity[0])
		
	imgui_text_tooltip('Aerated Glow:      ', 'Glow intensity of the micro-foam beneath the surface.')
	ImGui.SameLine()
	if ImGui.SliderFloat('##aerated_glow', _aerated_foam_glow, 0.0, 2.0): 
		water.get_active_material(0).set_shader_parameter("aerated_foam_glow", _aerated_foam_glow[0])
	# -------------------------------------------
	
	ImGui.SeparatorText('Wave Parameters')
	if ImGui.BeginTabBar('##cascades'):
		# CHANGED: Replaced len() with .size()
		for i in water.parameters.size():
			var params : WaveCascadeParameters = water.parameters[i]
			if ImGui.BeginTabItem('Cascade %d' % (i + 1)):
				imgui_text_tooltip('Tile Length:       ', 'Denotes the distance the cascade\'s tile should cover (in meters).')
				ImGui.SameLine()
				if ImGui.InputFloat2('##tile_length', params._tile_length): 
					params.tile_length = Vector2(params._tile_length[0], params._tile_length[1])
					
				imgui_text_tooltip('Displacement Scale:', '')
				ImGui.SameLine()
				if ImGui.SliderFloat('##displacement_scale', params._displacement_scale, 0.0, 2.0): 
					params.displacement_scale = params._displacement_scale[0]
					
				imgui_text_tooltip('Normal Scale:      ', '')
				ImGui.SameLine()
				if ImGui.SliderFloat('##normal_scale', params._normal_scale, 0.0, 2.0): 
					params.normal_scale = params._normal_scale[0]
					
				ImGui.Dummy(Vector2(0.0, 0.0)); ImGui.Separator(); ImGui.Dummy(Vector2(0.0, 0.0))
				
				imgui_text_tooltip('Wind Speed:        ', 'Denotes the average wind speed above the water (in meters per second).\nIncreasing makes waves steeper and more \'chaotic\'.')
				ImGui.SameLine()
				if ImGui.DragFloat('##wind_speed', params._wind_speed): 
					params.wind_speed = params._wind_speed[0]
					
				imgui_text_tooltip('Wind Direction:    ', '')
				ImGui.SameLine()
				if ImGui.SliderAngle('##wind_direction', params._wind_direction): 
					params.wind_direction = rad_to_deg(params._wind_direction[0])
					
				imgui_text_tooltip('Fetch Length:      ', 'Denotes the distance from shoreline (in kilometers).\nIncreasing makes waves steeper, but reduces their \'choppiness\'.')
				ImGui.SameLine()
				if ImGui.DragFloat('##fetch_length', params._fetch_length): 
					params.fetch_length = params._fetch_length[0]
					
				imgui_text_tooltip('Swell:             ', 'Modifies waves to clump in a more elongated, parallel manner.')
				ImGui.SameLine()
				if ImGui.SliderFloat('##swell', params._swell, 0.0, 2.0): 
					params.swell = params._swell[0]
					
				imgui_text_tooltip('Spread:            ', 'Modifies how much wind and swell affect the direction of the waves.')
				ImGui.SameLine()
				if ImGui.SliderFloat('##spread', params._spread, 0.0, 1.0): 
					params.spread = params._spread[0]
					
				imgui_text_tooltip('Detail:            ', 'Modifies the attenuation of high frequency waves.')
				ImGui.SameLine()
				if ImGui.SliderFloat('##detail', params._detail, 0.0, 1.0): 
					params.detail = params._detail[0]
					
				ImGui.Dummy(Vector2(0.0, 0.0)); ImGui.Separator(); ImGui.Dummy(Vector2(0.0, 0.0))
				
				imgui_text_tooltip('Whitecap:          ', 'Modifies how steep a wave needs to be before foam can accumulate.')
				ImGui.SameLine()
				if ImGui.SliderFloat('##white_cap', params._whitecap, 0.0, 2.0): 
					params.whitecap = params._whitecap[0]
					
				imgui_text_tooltip('Foam Amount:       ', '')
				ImGui.SameLine()
				if ImGui.SliderFloat('##foam_amount', params._foam_amount, 0.0, 10.0): 
					params.foam_amount = params._foam_amount[0]
					
				ImGui.EndTabItem()
		ImGui.EndTabBar()

	# --- TOOLS SECTION ---
	ImGui.SeparatorText('Tools')
	
	if ImGui.Button('Reset All to Default'):
		reset_to_defaults()
		
	ImGui.SameLine() # Puts the bake button on the exact same row!
	
	if ImGui.Button('Bake Current Waves to .RES'):
		water.bake_waves_to_res()
		
	ImGui.Dummy(Vector2(0.0, 5.0)) 
	# ---------------------

	ImGui.SeparatorText('Camera')
	# Using Godot's built-in formatting for Vector3 to 2 decimal places
	ImGui.Text('Camera Position:    %.2f, %.2f, %.2f' % [camera.global_position.x, camera.global_position.y, camera.global_position.z])
	ImGui.Text('Camera FOV:        ')
	ImGui.SameLine()
	if ImGui.SliderFloat('##fov_float', _camera_fov, 20.0, 170.0): 
		camera.fov = _camera_fov[0]

	ImGui.Dummy(Vector2(0.0, 0.0)); ImGui.Separator(); ImGui.Dummy(Vector2(0.0, 0.0))
	ImGui.PushStyleColor(ImGui.Col_Text, Color.WEB_GRAY)
	ImGui.Text('Press %s-H to toggle GUI visibility!' % ['Cmd' if OS.get_name() == 'macOS' else 'Ctrl'])
	ImGui.Text('Press %s-F to toggle fullscreen!' % ['Cmd' if OS.get_name() == 'macOS' else 'Ctrl'])
	ImGui.PopStyleColor()
	ImGui.End()

func reset_to_defaults() -> void:
	if _default_cache.is_empty(): return
	
	# 1. Reset Camera & Base Settings
	camera.fov = _default_cache["fov"]
	_camera_fov[0] = camera.fov
	
	water.map_size = _default_cache["map_size"]
	water.mesh_quality = _default_cache["mesh_quality"]
	clipmap_tile_size = _default_cache["clipmap_tile"]
	
	water.updates_per_second = _default_cache["updates"]
	_updates_per_second[0] = water.updates_per_second
	
	water.update_textures = _default_cache["update_tex"]
	_update_textures[0] = water.update_textures
	
	$Water/WaterSprayEmitter.visible = _default_cache["sea_spray"]
	_is_sea_spray_visible[0] = _default_cache["sea_spray"]
	
	# 2. Reset Colors
	water.water_color = _default_cache["water_color"]
	_water_color = [water.water_color.r, water.water_color.g, water.water_color.b]
	
	water.foam_color = _default_cache["foam_color"]
	_foam_color = [water.foam_color.r, water.foam_color.g, water.foam_color.b]
	
	var c_color : Color = _default_cache["crest_color"]
	_crest_color = [c_color.r, c_color.g, c_color.b]
	water.get_active_material(0).set_shader_parameter("crest_color", c_color)
	
	_crest_glow_intensity[0] = _default_cache["crest_glow"]
	water.get_active_material(0).set_shader_parameter("crest_glow_intensity", _crest_glow_intensity[0])
	
	_aerated_foam_glow[0] = _default_cache["aerated_glow"]
	water.get_active_material(0).set_shader_parameter("aerated_foam_glow", _aerated_foam_glow[0])
	
	# 3. Reset All Wave Cascades & Force GPU Update
	var original_cascades : Array[WaveCascadeParameters] = _default_cache["cascades"]
	for i in range(water.parameters.size()):
		var target : WaveCascadeParameters = water.parameters[i]
		var source : WaveCascadeParameters = original_cascades[i]
		
		# We must update BOTH the internal data and the ImGui array [0] reference
		target.tile_length = source.tile_length
		target._tile_length[0] = source.tile_length.x; target._tile_length[1] = source.tile_length.y
		target.displacement_scale = source.displacement_scale; target._displacement_scale[0] = source.displacement_scale
		target.normal_scale = source.normal_scale; target._normal_scale[0] = source.normal_scale
		target.wind_speed = source.wind_speed; target._wind_speed[0] = source.wind_speed
		target.wind_direction = source.wind_direction; target._wind_direction[0] = source.wind_direction
		target.fetch_length = source.fetch_length; target._fetch_length[0] = source.fetch_length
		target.swell = source.swell; target._swell[0] = source.swell
		target.spread = source.spread; target._spread[0] = source.spread
		target.detail = source.detail; target._detail[0] = source.detail
		target.whitecap = source.whitecap; target._whitecap[0] = source.whitecap
		target.foam_amount = source.foam_amount; target._foam_amount[0] = source.foam_amount
		
		# CRUCIAL: Tell the GPU compute shader to recalculate the FFT spectrums!
		target.should_generate_spectrum = true
