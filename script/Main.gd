extends Control
## Colorma MVP — Godot 4 移植版
## 單一腳本集中處理：減色混色、CIELAB ΔE 評分、長按連滴、Undo 懲罰、Tween 彈跳、結算 Split View。

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
## 每次 Undo 從精準度百分比扣點（百分點）
const UNDO_PENALTY_PERCENT := 0.5

## D65 參考白（用於 XYZ→Lab）
const REF_WHITE := Vector3(0.95047, 1.0, 1.08883)

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
# endregion

## 遊戲狀態
var _drops: Array[String] = []
var _target_color: Color = Color.WHITE
var _current_color: Color = Color.WHITE
var _secret_drops: Array[String] = []

## 長按：目前按住的是哪一種顏料（空字串表示未按住）
var _held_pigment: String = ""
## 本局 Undo 次數（影響結算精準度）
var _undo_count: int = 0

# region 生命週期
func _ready() -> void:
	# 背景色與 HTML 一致
	if _bg:
		_bg.color = Color.html("#0f0f0f")

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

	_modal.visible = false
	_modal.hide()

	start_new_round()

	# 等版面完成後，將調色盤縮放軸心置中（Tween 彈跳用）
	call_deferred("_refresh_mix_pivot")


func _refresh_mix_pivot() -> void:
	if _mix_swatch:
		_mix_swatch.pivot_offset = _mix_swatch.size * 0.5

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
	_undo_count += 0
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


## 將 ΔE 映射到 0~100 的「基礎精準度」再扣 Undo
func _accuracy_from_delta_e(de: float) -> float:
	## 使用平滑曲線：ΔE 越小分數越高；係數可依手感微調
	var base: float = clampf(100.0 * exp(-de / 40.0), 0.0, 100.0)
	return base

# endregion

# region 目標色生成（與玩家使用同一套混色函式，確保可解）
func _generate_target_color() -> void:
	var pool: Array[String] = ["R", "Y", "B", "W", "K"]
	var count: int = randi_range(2, 8)
	_secret_drops.clear()
	for i in count:
		_secret_drops.append(pool.pick_random())
	_target_color = calculate_color_from_drops(_secret_drops)
	_apply_panel_bg(_target_swatch, _target_color)
	print("Target secret drops: ", _secret_drops)

# endregion

# region 結算與新局
func _on_submit_pressed() -> void:
	var lab_t: Vector3 = rgb_to_lab(_target_color)
	var lab_c: Vector3 = rgb_to_lab(_current_color)
	var de: float = delta_e_76(lab_t, lab_c)

	var base_score: float = _accuracy_from_delta_e(de)
	var penalty: float = float(_undo_count) * UNDO_PENALTY_PERCENT
	var final_score: float = clampf(base_score - penalty, 0.0, 100.0)

	_score_label.text = "%.1f%%" % final_score
	_feedback_label.text = _feedback_for_score(final_score)
	_split_target.color = _target_color
	_split_player.color = _current_color

	## 高分用金色點綴（與 HTML accent 接近）
	if final_score >= 90.0:
		_score_label.add_theme_color_override("font_color", Color.html("#d4af37"))
	else:
		_score_label.add_theme_color_override("font_color", Color.html("#f0f0f0"))

	_modal.visible = true
	_modal.show()


func _feedback_for_score(s: float) -> String:
	if s >= 98.0:
		return "FLAWLESS PERFECT 神乎其技"
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
	_drops.clear()
	_undo_count = 0
	_generate_target_color()
	_update_mix_ui()


func _on_next_round_pressed() -> void:
	start_new_round()

# endregion
