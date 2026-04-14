extends Control

const GAME_SCENE := "res://scenes/Main.tscn"

@onready var _menu_root: Control = $UILayer/MenuRoot
@onready var _start_btn: Button = $UILayer/MenuRoot/StartButton
@onready var _profile_btn: Button = $UILayer/MenuRoot/ProfileButton
@onready var _settings_btn: Button = $UILayer/MenuRoot/SettingsButton
@onready var _friend_btn: Button = $UILayer/MenuRoot/FriendButton

var _final_rects: Dictionary = {}
var _opening_done: bool = false


func _ready() -> void:
	_set_buttons_interactive(false)
	_start_btn.pressed.connect(_on_start_pressed)
	_profile_btn.pressed.connect(_on_profile_pressed)
	_settings_btn.pressed.connect(_on_settings_pressed)
	_friend_btn.pressed.connect(_on_friend_pressed)

	await get_tree().process_frame
	await get_tree().process_frame
	_cache_button_rects()
	_apply_offscreen_starts()
	_play_opening_animation()


func _cache_button_rects() -> void:
	for b in [_start_btn, _profile_btn, _settings_btn, _friend_btn]:
		var gr: Rect2 = Rect2(b.global_position, b.size)
		_final_rects[b] = gr


func _to_local_rect(global_r: Rect2) -> Rect2:
	var origin: Vector2 = _menu_root.global_position
	return Rect2(global_r.position - origin, global_r.size)


func _freeze_manual_layout(btn: Button, global_r: Rect2) -> void:
	var lr: Rect2 = _to_local_rect(global_r)
	btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
	btn.position = lr.position
	btn.size = lr.size


## Profile 落下後暫停位置：在左半（與 Start 同一列、置中於左上格），之後被 Start 從左撞向右側定點
func _profile_staged_left_pos(start_rect: Rect2, profile_rect: Rect2) -> Vector2:
	return Vector2(
		start_rect.position.x + (start_rect.size.x - profile_rect.size.x) * 0.5,
		profile_rect.position.y
	)


func _apply_offscreen_starts() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var margin: float = 48.0

	var rs: Rect2 = _final_rects[_settings_btn]
	var rf: Rect2 = _final_rects[_friend_btn]
	var rp: Rect2 = _final_rects[_profile_btn]
	var rt: Rect2 = _final_rects[_start_btn]
	var profile_stage_left: Vector2 = _profile_staged_left_pos(rt, rp)

	_freeze_manual_layout(_settings_btn, rs)
	# 從螢幕右側外快速移向左下預定位置
	_settings_btn.global_position = Vector2(vp.x + margin, rs.position.y)

	_freeze_manual_layout(_friend_btn, rf)
	# 從上方墜落至右下
	_friend_btn.global_position = Vector2(rf.position.x, -rf.size.y - margin)

	_freeze_manual_layout(_profile_btn, rp)
	# 從上方墜落，路徑在螢幕左側（落在左上格暫停，尚未到右上定點）
	_profile_btn.global_position = Vector2(profile_stage_left.x, -rp.size.y - margin)

	_freeze_manual_layout(_start_btn, rt)
	# 從左側外衝向左上
	_start_btn.global_position = Vector2(-rt.size.x - margin, rt.position.y)


func _play_opening_animation() -> void:
	var rs: Rect2 = _final_rects[_settings_btn]
	var rf: Rect2 = _final_rects[_friend_btn]
	var rp: Rect2 = _final_rects[_profile_btn]
	var rt: Rect2 = _final_rects[_start_btn]
	var profile_stage_left: Vector2 = _profile_staged_left_pos(rt, rp)

	var tw_intro: Tween = create_tween()
	tw_intro.set_parallel(true)
	tw_intro.tween_property(
		_settings_btn, "global_position", rs.position, 0.32
	).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	tw_intro.tween_property(
		_friend_btn, "global_position", rf.position, 0.36
	).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN)

	await tw_intro.finished
	await get_tree().create_timer(0.06).timeout

	# Profile 先墜至左側（左上格）；此時 Start 仍在螢幕左外待命
	var tw_profile_fall: Tween = create_tween()
	tw_profile_fall.tween_property(
		_profile_btn, "global_position", profile_stage_left, 0.38
	).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN)

	await tw_profile_fall.finished
	await get_tree().create_timer(0.1).timeout

	# Start 從左側衝入定點，同時把 Profile 從左側一路推到右上定點
	var tw_charge: Tween = create_tween()
	tw_charge.set_parallel(true)
	tw_charge.tween_property(
		_start_btn, "global_position", rt.position, 0.52
	).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw_charge.tween_property(
		_profile_btn, "global_position", rp.position, 0.52
	).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)

	await tw_charge.finished
	_opening_done = true
	_set_buttons_interactive(true)


func _set_buttons_interactive(enabled: bool) -> void:
	for b in [_start_btn, _profile_btn, _settings_btn, _friend_btn]:
		b.disabled = not enabled
		b.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE


func _on_start_pressed() -> void:
	if not _opening_done:
		return
	get_tree().change_scene_to_file(GAME_SCENE)


func _on_profile_pressed() -> void:
	print("ProfileButton: 個人檔案（調試）")


func _on_settings_pressed() -> void:
	print("SettingsButton: 設定（調試）")


func _on_friend_pressed() -> void:
	print("FriendButton: 好友連機（調試）")
