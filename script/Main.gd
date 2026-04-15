extends Control
## Colorma MVP — Godot 4 移植版
## 單一腳本集中處理：減色混色、CIELAB ΔE 評分、長按連滴、Tween 彈跳、結算 Split View。

# region 常數與顏料設定
## HTML 原版：RYB 映射到虛擬 CMY 吸收空間（減色法直覺）
const PIGMENT_PROFILES := {
	"R": Vector3(0.0, 1.0, 1.0), # C, M, Y 吸收係數
	"Y": Vector3(0.0, 0.0, 1.0),
	"B": Vector3(1.0, 0.2, 0.0),
	"W": Vector3(0.0, 0.0, 0.0),
	"K": Vector3(1.0, 1.0, 1.0),
}

## 染色力（Tinting Strength）：K、B 明顯大於 Y、W
const TINT_STRENGTH := {
	"K": 2.5,
	"B": 2.0,
	"R": 1.0,
	"Y": 0.45,
	"W": 0.28,
}

## 長按連滴間隔（秒）
const HOLD_DROP_INTERVAL := 0.2

## D65 參考白（用於 XYZ→Lab）
const REF_WHITE := Vector3(0.95047, 1.0, 1.08883)

const HP_MAX := 10000
const HP_INITIAL := 10000
## 難度用顏料池（關卡越高可選越多色）
const POOL_3_COLORS: Array[String] = ["R", "Y", "B"]
const POOL_4_COLORS: Array[String] = ["R", "Y", "B", "W"]
const POOL_5_COLORS: Array[String] = ["R", "Y", "B", "W", "K"]

const HUD_HP_TEXT_NORMAL := Color(0.941176, 0.941176, 0.941176, 1)
const HUD_HEART_NORMAL := Color(1, 1, 1, 1)
const HUD_HP_DAMAGE := Color(1.0, 0.35, 0.35, 1)
const HUD_HP_HEAL := Color(0.38, 0.96, 0.48, 1)

## 極深色（低 L*）：人眼對色差較不敏感，放寬 ΔE 對應分數時的有效除數
const LOW_L_STAR_THRESHOLD := 10.0
const DARK_PAIR_DE_RELAX := 1.75

const DISCREPANCY_REPORT_PATH := "user://discrepancy_reports.jsonl"
const MENU_BALL_TRANSITION_META_KEY := "menu_ball_transition_payload"

# endregion

# region 節點引用
@onready var _bg: ColorRect = $Background
@onready var _hold_timer: Timer = $HoldTimer

@onready var _target_swatch: Panel = %TargetSwatch
@onready var _mix_swatch: Panel = %MixSwatch
@onready var _drop_label: Label = %DropLabel

@onready var _btn_r: Button = %BtnR
@onready var _btn_y: Button = %BtnY
@onready var _btn_b: Button = %BtnB
@onready var _btn_w: Button = %BtnW
@onready var _btn_k: Button = %BtnK

@onready var _btn_clear: Button = %BtnClear
@onready var _btn_undo: Button = %BtnUndo
@onready var _btn_submit: Button = %BtnSubmit

@onready var _modal: Control = %ResultModal
@onready var _score_label: Label = %ScoreLabel
@onready var _feedback_label: Label = %FeedbackLabel
@onready var _split_target: ColorRect = %SplitTargetColor
@onready var _split_player: ColorRect = %SplitPlayerColor
@onready var _btn_next: Button = %BtnNext
@onready var _btn_home: Button = %HomeButton
@onready var _hp_label: Label = %HPLabel
@onready var _heart_icon: Label = %HeartIcon
@onready var _stage_label: Label = %StageLabel
@onready var _result_title: Label = %ResultTitle
@onready var _test_mode_toggle: CheckButton = %TestModeToggle
@onready var _btn_report_discrepancy: Button = %BtnReportDiscrepancy
@onready var _report_saved_label: Label = %ReportSavedLabel
# endregion

## 遊戲狀態
var _hp: float = HP_INITIAL
## 畫面上數字動畫用（與 _hp 同步至終點）
var _hp_display: float = HP_INITIAL
var _hp_tween: Tween
var _stage: int = 1
var _game_over: bool = false

var _drops: Array[String] = []
var _target_color: Color = Color.WHITE
var _current_color: Color = Color.WHITE
var _secret_drops: Array[String] = []

## 長按：目前按住的是哪一種顏料（空字串表示未按住）
var _held_pigment: String = ""
## 本局 Undo 次數（影響結算精準度）
var _undo_count: int = 0

## 結算彈窗開啟時的快照（供測試模式上報）
var _last_delta_e: float = 0.0
var _last_final_score: float = 0.0
var _last_drops_snapshot: Array[String] = []
var _menu_ball_payload: Dictionary = {}
var _menu_ball_overlay: Control
var _menu_ball_primary: Panel
var _menu_ball_secondary: Panel

# region 生命週期
func _enter_tree() -> void:
	_prepare_menu_ball_transition_overlay()


func _ready() -> void:
	# 背景色與 HTML 一致
	if _bg:
		_bg.color = Color.html("#0f0f0f")
	_play_menu_ball_transition_if_needed()

	_hold_timer.wait_time = HOLD_DROP_INTERVAL
	_hold_timer.one_shot = false
	_hold_timer.timeout.connect(_on_hold_timer_tick)

	_connect_pigment_button(_btn_r, "R")
	_connect_pigment_button(_btn_y, "Y")
	_connect_pigment_button(_btn_b, "B")
	_connect_pigment_button(_btn_w, "W")
	_connect_pigment_button(_btn_k, "K")

	_btn_clear.pressed.connect(_on_clear_pressed)
	_btn_undo.pressed.connect(_on_undo_pressed)
	_btn_submit.pressed.connect(_on_submit_pressed)
	_btn_next.pressed.connect(_on_next_round_pressed)
	_btn_home.pressed.connect(_on_home_pressed)
	_btn_report_discrepancy.pressed.connect(_report_issue)
	_test_mode_toggle.toggled.connect(_on_test_mode_toggled)

	_modal.visible = false
	_modal.hide()

	_update_hp_label_immediate()
	_update_stage_label()
	start_new_round()

	# 等版面完成後，將調色盤縮放軸心置中（Tween 彈跳用）
	call_deferred("_refresh_mix_pivot")


func _play_menu_ball_transition_if_needed() -> void:
	if _menu_ball_overlay == null or _menu_ball_primary == null or _menu_ball_secondary == null:
		return
	var vp: Vector2 = get_viewport_rect().size
	var center := vp * 0.5
	var primary_diameter: float = float(_menu_ball_payload.get("primary_diameter", vp.length() * 2.2))
	var secondary_diameter: float = float(_menu_ball_payload.get("secondary_diameter", primary_diameter))
	var duration: float = float(_menu_ball_payload.get("shrink_duration", 0.52))
	var delay: float = float(_menu_ball_payload.get("shrink_delay", 0.02))

	var tw := create_tween()
	tw.tween_interval(maxf(0.0, delay))
	tw.set_parallel(true)
	tw.tween_method(
		func(d: float): _set_transition_ball_geometry(_menu_ball_primary, center, d),
		primary_diameter,
		2.0,
		duration
	).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN_OUT)
	tw.tween_method(
		func(d: float): _set_transition_ball_geometry(_menu_ball_secondary, center, d),
		secondary_diameter,
		2.0,
		duration
	).set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	if _menu_ball_overlay:
		_menu_ball_overlay.queue_free()
	_menu_ball_overlay = null
	_menu_ball_primary = null
	_menu_ball_secondary = null


func _prepare_menu_ball_transition_overlay() -> void:
	if not get_tree().has_meta(MENU_BALL_TRANSITION_META_KEY):
		return
	var payload: Variant = get_tree().get_meta(MENU_BALL_TRANSITION_META_KEY)
	get_tree().remove_meta(MENU_BALL_TRANSITION_META_KEY)
	if not (payload is Dictionary):
		return
	_menu_ball_payload = payload

	var vp: Vector2 = get_viewport().get_visible_rect().size
	if vp == Vector2.ZERO:
		return
	var center := vp * 0.5
	var primary_diameter: float = float(_menu_ball_payload.get("primary_diameter", vp.length() * 2.2))
	var secondary_diameter: float = float(_menu_ball_payload.get("secondary_diameter", primary_diameter))
	var primary_color: Color = _menu_ball_payload.get("primary_color", Color(0.52, 0.52, 0.52, 1.0))
	var secondary_color: Color = _menu_ball_payload.get("secondary_color", Color(0.22, 0.22, 0.22, 1.0))

	_menu_ball_overlay = Control.new()
	_menu_ball_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_menu_ball_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_menu_ball_overlay.z_index = 999
	add_child(_menu_ball_overlay)

	_menu_ball_primary = Panel.new()
	_menu_ball_primary.add_theme_stylebox_override("panel", _make_transition_ball_style(primary_color))
	_menu_ball_overlay.add_child(_menu_ball_primary)
	_set_transition_ball_geometry(_menu_ball_primary, center, primary_diameter)

	_menu_ball_secondary = Panel.new()
	_menu_ball_secondary.add_theme_stylebox_override("panel", _make_transition_ball_style(secondary_color))
	_menu_ball_overlay.add_child(_menu_ball_secondary)
	_set_transition_ball_geometry(_menu_ball_secondary, center, secondary_diameter)


func _make_transition_ball_style(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.corner_radius_top_left = 2048
	sb.corner_radius_top_right = 2048
	sb.corner_radius_bottom_left = 2048
	sb.corner_radius_bottom_right = 2048
	return sb


func _set_transition_ball_geometry(ball: Control, center: Vector2, diameter: float) -> void:
	if ball == null:
		return
	ball.size = Vector2(diameter, diameter)
	ball.position = center - ball.size * 0.5


func _refresh_mix_pivot() -> void:
	if _mix_swatch:
		_mix_swatch.pivot_offset = _mix_swatch.size * 0.5


## 每 5 關更新難度參數；第 11 關起滴數與扣血倍率隨關卡增加
func _get_difficulty_profile(stage: int) -> Dictionary:
	if stage <= 4:
		return {
			"min_drops": 2,
			"max_drops": 4,
			"pigment_pool": POOL_3_COLORS.duplicate(),
			"damage_mult": 1.0,
		}
	if stage <= 10:
		return {
			"min_drops": 3,
			"max_drops": 6,
			"pigment_pool": POOL_4_COLORS.duplicate(),
			"damage_mult": 1.2,
		}
	var block: int = int(floor((stage - 11) / 5.0))
	var damage_mult: float = 1.2 + 0.15 * float(block + 1)
	var max_drops: int = 6 + block * 2
	var min_drops: int = 3 + block
	min_drops = clampi(min_drops, 2, max_drops)
	return {
		"min_drops": min_drops,
		"max_drops": max_drops,
		"pigment_pool": POOL_5_COLORS.duplicate(),
		"damage_mult": damage_mult,
	}


func _update_hp_label_immediate() -> void:
	_hp_display = _hp
	if _hp_label:
		_hp_label.text = "%d" % int(round(_hp))
	_reset_hud_health_colors()


func _update_stage_label() -> void:
	if _stage_label:
		_stage_label.text = "%d ⭐" % _stage


func _set_hud_health_colors(num: Color, heart: Color) -> void:
	if _hp_label:
		_hp_label.add_theme_color_override("font_color", num)
	if _heart_icon:
		_heart_icon.add_theme_color_override("font_color", heart)


func _reset_hud_health_colors() -> void:
	_set_hud_health_colors(HUD_HP_TEXT_NORMAL, HUD_HEART_NORMAL)


## 扣血：紅色 + 數字快速下降；回血：綠色 + 較活潑曲線；結束恢復白字
func _play_hp_change_animation(from_val: float, to_val: float, hp_delta: float) -> void:
	to_val = clampf(to_val, 0.0, float(HP_MAX))
	if _hp_tween and is_instance_valid(_hp_tween):
		_hp_tween.kill()

	if absf(hp_delta) < 0.0001:
		_hp_display = to_val
		_on_hp_display_step(to_val)
		_reset_hud_health_colors()
		return

	var tw := create_tween()
	_hp_tween = tw

	if hp_delta < 0.0:
		_set_hud_health_colors(HUD_HP_DAMAGE, HUD_HP_DAMAGE)
		tw.tween_method(_on_hp_display_step, from_val, to_val, 1.5).set_trans(Tween.TRANS_QUAD).set_ease(
			Tween.EASE_IN
		)
	else:
		_set_hud_health_colors(HUD_HP_HEAL, HUD_HP_HEAL)
		## 回血：快速上升、無彈跳
		tw.tween_method(_on_hp_display_step, from_val, to_val, 0.28).set_trans(Tween.TRANS_QUAD).set_ease(
			Tween.EASE_OUT
		)

	tw.tween_callback(_reset_hud_health_colors)


func _on_hp_display_step(v: float) -> void:
	_hp_display = clampf(v, 0.0, float(HP_MAX))
	if _hp_label:
		_hp_label.text = "%d" % int(round(_hp_display))


## 依本局分數計算 HP 變化（回血不受 damage_mult；扣血會乘倍率）
func _compute_hp_delta(final_score: float, damage_mult: float) -> float:
	if final_score >= 99.5:
		return 2000.0
	if final_score >= 96.0:
		return lerp(300.0, 1000.0, (final_score - 96.0) / 3.5)
	## 90%～96%：少許回血（10～200）
	if final_score >= 90.0:
		return lerp(10.0, 200.0, (final_score - 90.0) / 6.0)
	if final_score >= 88.0:
		return -lerp(100.0, 500.0, (96.0 - final_score) / 8.0) * damage_mult
	if final_score >= 60.0:
		return -lerp(500.0, 2500.0, (88.0 - final_score) / 28.0) * damage_mult
	return -lerp(2500.0, 5000.0, (60.0 - final_score) / 60.0) * damage_mult


func game_over() -> void:
	_game_over = true

# endregion

# region 顏料按鈕連線
func _connect_pigment_button(btn: Button, pigment: String) -> void:
	btn.button_down.connect(func(): _on_pigment_button_down(pigment))
	btn.button_up.connect(_on_pigment_button_up)


func _on_pigment_button_down(pigment: String) -> void:
	_held_pigment = pigment
	# 第一滴立即滴入
	add_drop(pigment)
	_hold_timer.start()


func _on_pigment_button_up() -> void:
	_hold_timer.stop()
	_held_pigment = ""


func _on_hold_timer_tick() -> void:
	if _held_pigment.is_empty():
		return
	add_drop(_held_pigment)

# endregion

# region 混色核心（簡化 Kubelka-Munk 風格：權重平均 + 厚度非線性變暗）
## 依滴數列表計算顯示色。空畫布為白紙。
func calculate_color_from_drops(drops: Array) -> Color:
	if drops.is_empty():
		return Color.WHITE

	var sum_w: float = 0.0
	var acc := Vector3.ZERO

	for d in drops:
		if not PIGMENT_PROFILES.has(d):
			continue
		var prof: Vector3 = PIGMENT_PROFILES[d]
		var s: float = float(TINT_STRENGTH.get(d, 1.0))
		sum_w += s
		acc.x += s * prof.x
		acc.y += s * prof.y
		acc.z += s * prof.z

	if sum_w <= 0.0001:
		return Color.WHITE

	## 權重平均後的「有效濃度」CMY（0~1）
	var avg := acc / sum_w
	avg.x = clampf(avg.x, 0.0, 1.0)
	avg.y = clampf(avg.y, 0.0, 1.0)
	avg.z = clampf(avg.z, 0.0, 1.0)

	## 標準 CMY→RGB（與 HTML 一致）
	var r := 255.0 * (1.0 - avg.x)
	var g := 255.0 * (1.0 - avg.y)
	var b := 255.0 * (1.0 - avg.z)

	## 厚度感：僅非白色滴數參與變暗（白顏料稀釋但不增加「堆疊厚度」）
	var n_actual: float = 0.0
	for d in drops:
		if d != "W":
			n_actual += 1.0
	var dark_mul: float = 1.0 / (1.0 + 0.14 * pow(n_actual, 0.82))
	r *= dark_mul
	g *= dark_mul
	b *= dark_mul

	return Color(r / 255.0, g / 255.0, b / 255.0)


func _update_mix_ui() -> void:
	_current_color = calculate_color_from_drops(_drops)
	_apply_panel_bg(_mix_swatch, _current_color)

	var n: int = _drops.size()
	if n == 0:
		_drop_label.text = "0 DROPS"
	elif n == 1:
		_drop_label.text = "1 DROP"
	else:
		_drop_label.text = "%d DROPS" % n


## 執行期僅更新 Panel 的底色（形狀／邊框在 scenes/Main.tscn 的 StyleBoxFlat）
func _apply_panel_bg(panel: Panel, c: Color) -> void:
	var sb := panel.get_theme_stylebox("panel") as StyleBoxFlat
	if sb == null:
		sb = StyleBoxFlat.new()
		panel.add_theme_stylebox_override("panel", sb)
	sb.bg_color = c

# endregion

# region 滴落 / 清除 / Undo
func add_drop(pigment: String) -> void:
	_drops.append(pigment)
	_update_mix_ui()
	_play_mix_bounce()


func _on_clear_pressed() -> void:
	_drops.clear()
	_undo_count = 0
	_update_mix_ui()


func _on_undo_pressed() -> void:
	if _drops.is_empty():
		return
	_drops.pop_back()
	_undo_count += 1
	_update_mix_ui()

# endregion

# region Juice：調色盤縮放彈跳（Tween.TRANS_SPRING）
func _play_mix_bounce() -> void:
	var ctrl: Control = _mix_swatch
	var tw := create_tween()
	## 放大段用平滑曲線；回彈段用 TRANS_SPRING 呈現 Q 彈感
	tw.tween_property(ctrl, "scale", Vector2(1.08, 1.08), 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.chain().tween_property(ctrl, "scale", Vector2.ONE, 0.45).set_trans(Tween.TRANS_SPRING).set_ease(Tween.EASE_OUT)

# endregion

# region CIELAB 與 ΔE（結算分數）
func _linearize_srgb_u8(channel: float) -> float:
	## channel: 0~1 sRGB
	var c: float = clampf(channel, 0.0, 1.0)
	if c <= 0.04045:
		return c / 12.92
	return pow((c + 0.055) / 1.055, 2.4)


func rgb_color_to_xyz(c: Color) -> Vector3:
	var r: float = _linearize_srgb_u8(c.r)
	var g: float = _linearize_srgb_u8(c.g)
	var b: float = _linearize_srgb_u8(c.b)
	## sRGB(D65) → XYZ 矩陣
	var x: float = r * 0.4124564 + g * 0.3575761 + b * 0.1804375
	var y: float = r * 0.2126729 + g * 0.7151522 + b * 0.0721750
	var z: float = r * 0.0193339 + g * 0.1191920 + b * 0.9503041
	return Vector3(x, y, z)


func _lab_f(t: float) -> float:
	if t > 0.008856:
		return pow(t, 1.0 / 3.0)
	return (7.787 * t) + (16.0 / 116.0)


func xyz_to_lab(xyz: Vector3) -> Vector3:
	var xr: float = xyz.x / REF_WHITE.x
	var yr: float = xyz.y / REF_WHITE.y
	var zr: float = xyz.z / REF_WHITE.z

	var fx: float = _lab_f(xr)
	var fy: float = _lab_f(yr)
	var fz: float = _lab_f(zr)

	var L: float = (116.0 * fy) - 16.0
	var a: float = 500.0 * (fx - fy)
	var b_: float = 200.0 * (fy - fz)
	return Vector3(L, a, b_)


func rgb_to_lab(c: Color) -> Vector3:
	return xyz_to_lab(rgb_color_to_xyz(c))


## CIE76：ΔE = sqrt(ΔL² + Δa² + Δb²)
func delta_e_76(lab1: Vector3, lab2: Vector3) -> float:
	var d: Vector3 = lab1 - lab2
	return sqrt(d.x * d.x + d.y * d.y + d.z * d.z)


## 將 ΔE 映射到 0~100 的「基礎精準度」。雙方皆為極深色時放寬有效 ΔE，貼近低亮度下的視覺經驗。
func _accuracy_from_delta_e(de: float, lab_target: Vector3, lab_player: Vector3) -> float:
	var de_eff: float = de
	if lab_target.x < LOW_L_STAR_THRESHOLD and lab_player.x < LOW_L_STAR_THRESHOLD:
		de_eff = de / DARK_PAIR_DE_RELAX
	var base: float = clampf(100.0 * exp(-de_eff /23.0), 0.0, 100.0)
	return base

# endregion

# region 目標色生成（與玩家使用同一套混色函式，確保可解）
func _generate_target_color() -> void:
	var prof: Dictionary = _get_difficulty_profile(_stage)
	var pool: Array[String] = prof["pigment_pool"]
	var mn: int = int(prof["min_drops"])
	var mx: int = int(prof["max_drops"])
	var count: int = randi_range(mn, mx)
	_secret_drops.clear()
	for i in count:
		_secret_drops.append(pool.pick_random())
	_target_color = calculate_color_from_drops(_secret_drops)
	_apply_panel_bg(_target_swatch, _target_color)

# endregion

# region 結算與新局
func _on_submit_pressed() -> void:
	var lab_t: Vector3 = rgb_to_lab(_target_color)
	var lab_c: Vector3 = rgb_to_lab(_current_color)
	var de: float = delta_e_76(lab_t, lab_c)

	_last_delta_e = de
	_last_drops_snapshot = _drops.duplicate()

	var base_score: float = _accuracy_from_delta_e(de, lab_t, lab_c)
	## Undo 不影響結算分數
	var final_score: float = clampf(base_score, 0.0, 100.0)
	_last_final_score = final_score

	var prof: Dictionary = _get_difficulty_profile(_stage)
	var dmg_mult: float = float(prof["damage_mult"])
	var hp_delta: float = _compute_hp_delta(final_score, dmg_mult)
	var from_display: float = _hp_display
	_hp = clampf(_hp + hp_delta, 0.0, float(HP_MAX))
	_play_hp_change_animation(from_display, _hp, hp_delta)

	var died: bool = _hp <= 0.0
	if died:
		game_over()

	_score_label.text = "%.1f%%" % final_score
	_split_target.color = _target_color
	_split_player.color = _current_color

	if died:
		_result_title.text = "GAME OVER"
		_feedback_label.text = "生命值歸零"
		_score_label.add_theme_color_override("font_color", Color.html("#ff5555"))
		_btn_next.text = "重新開始"
		_btn_home.visible = true
	else:
		_result_title.text = "ACCURACY MATCH"
		_feedback_label.text = _feedback_for_score(final_score)
		if final_score >= 90.0:
			_score_label.add_theme_color_override("font_color", Color.html("#d4af37"))
		else:
			_score_label.add_theme_color_override("font_color", Color.html("#f0f0f0"))
		_btn_next.text = "NEXT ROUND"
		_btn_home.visible = false

	if _report_saved_label:
		_report_saved_label.visible = false
	_btn_report_discrepancy.visible = _test_mode_toggle.button_pressed

	_modal.visible = true
	_modal.show()


func _color_to_hex(c: Color) -> String:
	return "#" + c.to_html(false)


func _on_test_mode_toggled(_pressed: bool) -> void:
	if _modal and _modal.visible:
		_btn_report_discrepancy.visible = _test_mode_toggle.button_pressed


func _report_issue() -> void:
	if not _test_mode_toggle.button_pressed:
		return
	var payload := {
		"target_hex": _color_to_hex(_target_color),
		"player_hex": _color_to_hex(_current_color),
		"delta_e": _last_delta_e,
		"accuracy_percent": _last_final_score,
		"drops": _last_drops_snapshot.duplicate(),
		"timestamp": Time.get_datetime_string_from_system(false, true),
	}
	if _append_discrepancy_report_line(payload):
		print("Report Saved: ", JSON.stringify(payload))
		if _report_saved_label:
			_report_saved_label.visible = true
			get_tree().create_timer(2.5).timeout.connect(
				func(): _hide_report_saved_if_still_open()
			)


func _hide_report_saved_if_still_open() -> void:
	if _report_saved_label and _modal.visible:
		_report_saved_label.visible = false


## 以 JSON Lines 附加寫入；檔案不存在時先建立。
func _append_discrepancy_report_line(obj: Dictionary) -> bool:
	var path := DISCREPANCY_REPORT_PATH
	if not FileAccess.file_exists(path):
		var create := FileAccess.open(path, FileAccess.WRITE)
		if create == null:
			push_error("無法建立 discrepancy_reports.jsonl")
			return false
		create.close()
	var file := FileAccess.open(path, FileAccess.READ_WRITE)
	if file == null:
		push_error("無法開啟 discrepancy_reports.jsonl")
		return false
	file.seek_end()
	file.store_line(JSON.stringify(obj))
	file.close()
	return true


func _feedback_for_score(s: float) -> String:
	if s == 100.0:
		return "FLAWLESS PERFECT 神乎其技"
	if s >= 96.0:
		return "PERFECT 完美"
	if s >= 90.0:
		return "EXCELLENT 優秀"
	if s >= 80.0:
		return "GOOD 不錯的直覺"
	if s >= 60.0:
		return "ACCEPTABLE 差強人意"
	return "POOR 完全偏離"


func start_new_round() -> void:
	_modal.hide()
	_modal.visible = false
	if _btn_home:
		_btn_home.visible = false
	if _report_saved_label:
		_report_saved_label.visible = false
	_drops.clear()
	_undo_count = 0
	_generate_target_color()
	_update_mix_ui()


func _full_restart() -> void:
	_game_over = false
	_stage = 1
	_hp = float(HP_INITIAL)
	_undo_count = 0
	_update_hp_label_immediate()
	_update_stage_label()
	start_new_round()


func _on_home_pressed() -> void:
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")


func _on_next_round_pressed() -> void:
	if _game_over:
		_full_restart()
		return
	_stage += 1
	_update_stage_label()
	start_new_round()

# endregion
