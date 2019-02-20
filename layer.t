
setfenv(1, require'low')
require'cairo2'
import'oops'

--types ----------------------------------------------------------------------

local num = double --cairo type for color channels, coordinates, etc.
local num2 = {num, num}
local num4 = {num, num, num, num}
local color = cairo_color_t

local struct point {x: num, y: num}

local struct rect {x: num, y: num, w: num, h: num}

rect.metamethods.__entrymissing = macro(function(name, obj)
	if name == 'x1' then return `self.x end
	if name == 'y1' then return `self.y end
	if name == 'x2' then return `self.x + self.w end
	if name == 'y2' then return `self.y + self.h end
end)

rect.metamethods.__setentry = macro(function(name, obj, rhs)
	if name == 'x1' then return quote self.x = rhs end end
	if name == 'y1' then return quote self.y = rhs end end
	if name == 'x2' then return quote self.w = rhs - self.x end end
	if name == 'y2' then return quote self.h = rhs - self.y end end
end)

--utils ----------------------------------------------------------------------

local terra snap(x: num, enable: bool)
	return iif(enable, floor(x + .5), x)
end

local terra snap_xw(x: num, w: num, enable: bool)
	if not enable then return x, w end
	var x1 = floor(x + .5)
	var x2 = floor(x + w + .5)
	return x1, x2 - x1
end

local terra snap_up(x: num, enable: bool)
	return iif(enable, ceil(x), x)
end

--offset a rectangle by d (outward if d is positive)
local terra box2d_offset(d: num, x: num, y: num, w: num, h: num): num4
	return x - d, y - d, w + 2*d, h + 2*d
end

--windows --------------------------------------------------------------------

local class window end

method window:to_screen(x: num, y :num): num2 return x, y end
method window:from_screen(x: num, y :num): num2 return x, y end

--layer hierarchy ------------------------------------------------------------

local class layer end

field layer.window: &window = nil

field layer.children: arr(layer)
field layer.parent: &layer = nil
field layer.pos_parent: &layer = nil

method layer:remove_layer(e: &layer)
	var i = self.children:indexat(e)
	self.children:remove(i)
end

method layer:add_layer(e: &layer)
	assert(self.children:add(@e) ~= -1)
	if e.parent ~= nil then
		e.parent:remove_layer(e)
	end
	e.parent = self
end

method layer:set_layer_index(e: &layer, i: int)
	var i0 = self.children:indexat(e); assert(i0 ~= -1)
	i = clamp(i, 0, self.children.len-1)
	if i0 == i then return end
	var e = @e
	self.children:remove(i0)
	assert(self.children:insert(i, e))
end

layer.metamethods.__call = macro(function(self, i)
	return `self.children:at(i)
end)

--layer relative geometry & matrix -------------------------------------------

field layer.x: num = 0
field layer.y: num = 0
field layer.w: num = 0
field layer.h: num = 0
field layer.rotation: num = 0
field layer.rotation_cx: num = 0
field layer.rotation_cy: num = 0
field layer.scale: num = 1
field layer.scale_cx: num = 0
field layer.scale_cy: num = 0
field layer.snap_x = true --snap to pixels on x-axis
field layer.snap_y = true --snap to pixels on y-axis

method layer:snapx(x) return `snap(x, self.snap_x) end
method layer:snapy(y) return `snap(y, self.snap_y) end
method layer:snapxw(x, w) return `snap_xw(x, w, self.snap_x) end
method layer:snapyh(y, h) return `snap_xw(y, h, self.snap_y) end
method layer:snapcx(cx) return `snap(cx-self.cx, self.snap_x)+self.cx end
method layer:snapcy(cy) return `snap(cy-self.cy, self.snap_y)+self.cy end

method layer:rel_matrix(): cairo_matrix_t --box matrix relative to parent's content space
	var mt: cairo_matrix_t; mt:init()
	mt:translate(self:snapx(self.x), self:snapy(self.y))
	if self.rotation ~= 0 then
		mt:rotate_around(self.rotation_cx, self.rotation_cy, rad(self.rotation))
	end
	if self.scale ~= 1 then
		mt:scale_around(self.scale_cx, self.scale_cy, self.scale, self.scale)
	end
	return mt
end

method layer:abs_matrix(): cairo_matrix_t --box matrix in window space
	var mt = self.pos_parent:abs_matrix()
	mt:transform(self:rel_matrix())
	return mt
end

method layer:cr_abs_matrix(cr: &cairo_t): cairo_matrix_t --box matrix in cr's current space
	if self.pos_parent ~= self.parent then
		return self:abs_matrix()
	else
		var m = cr:matrix()
		m:transform(self:rel_matrix())
		return m
	end
end

--convert point from own box space to parent content space.
method layer:from_box_to_parent(x: num, y: num): num2
	if self.pos_parent ~= self.parent then
		var m = self:abs_matrix()
		var x, y = m:point(x, y)
		return self.parent:from_window(x, y)
	else
		var m = self:rel_matrix()
		return m:point(x, y)
	end
end

--convert point from parent content space to own box space.
method layer:from_parent_to_box(x: num, y: num): num2
	if self.pos_parent ~= self.parent then
		x, y = self.parent:to_window(x, y)
		var m = self:abs_matrix(); m:invert()
		return m:point(x, y)
	else
		var m = self:rel_matrix(); m:invert()
		return m:point(x, y)
	end
end

--convert point from own content space to parent content space.
method layer:to_parent(x: num, y: num): num2
	if self.pos_parent ~= self.parent then
		var m = self:abs_matrix()
		x, y = self:padding_pos()
		m:translate(x, y)
		x, y = m:point(x, y)
		return self.parent:from_window(x, y)
	else
		var m = self:rel_matrix()
		x, y = self:padding_pos()
		m:translate(x, y)
		return m:point(x, y)
	end
end

--convert point from parent content space to own content space.
method layer:from_parent(x: num, y: num): num2
	if self.pos_parent ~= self.parent then
		var m = self:abs_matrix()
		x, y = self:padding_pos()
		m:translate(x, y)
		m:invert()
		x, y = self.parent:to_window(x, y)
		return m:point(x, y)
	else
		var m = self:rel_matrix()
		x, y = self:padding_pos()
		m:translate(x, y)
		m:invert()
		return m:point(x, y)
	end
end

method layer:to_window(x: num, y: num): num2 --parent & child interface
	var x, y = self:to_parent(x, y)
	return self.parent:to_window(x, y)
end

method layer:from_window(x: num, y: num): num2 --parent & child interface
	var x, y = self.parent:from_window(x, y)
	return self:from_parent(x, y)
end

method layer:to_screen(x: num, y: num): num2
	var x, y = self:to_window(x, y)
	return self.window:to_screen(x, y)
end

method layer:from_screen(x: num, y: num): num2
	var x, y = self.window:from_screen(x, y)
	return self:from_window(x, y)
end

--convert point from own content space to other's content space.
method layer:to_other(widget: &layer, x: num, y: num): num2
	if widget.window == self.window then
		x, y = self:to_window(x, y)
		return widget:from_window(x, y)
	else
		x, y = self:to_screen(x, y)
		return widget:from_screen(x, y)
	end
end

--convert point from other's content space to own content space
method layer:from_other(widget, x, y)
	return widget:to_other(self, x, y)
end

--[[
--bounding box of a rectangle in another layer's content box.
function layer:rect_bbox_in(other, x, y, w, h)
	local x1, y1 = self:to_other(other, x,     y)
	local x2, y2 = self:to_other(other, x + w, y)
	local x3, y3 = self:to_other(other, x,     y + h)
	local x4, y4 = self:to_other(other, x + w, y + h)
	local bx1 = min(x1, x2, x3, x4)
	local bx2 = max(x1, x2, x3, x4)
	local by1 = min(y1, y2, y3, y4)
	local by2 = max(y1, y2, y3, y4)
	return bx1, by1, bx2 - bx1, by2 - by1
end

--bounding box of a list of points in another layer's content box.
function layer:points_bbox_in(other, t) --t: {x1, y1, x2, y2, ...}
	local n = #t
	assert(n >= 2 and n % 2 == 0)
	local x1, y1, x2, y2 = 1/0, 1/0, -1/0, -1/0
	for i = 1, n, 2 do
		local x, y = t[i], t[i+1]
		local x, y = self:to_other(other, x, y)
		x1 = min(x1, x)
		y1 = min(y1, y)
		x2 = max(x2, x)
		y2 = max(y2, y)
	end
	return x1, y1, x2-x1, y2-y1
end

--layer parent property & child list -----------------------------------------

layer._parent = false

function layer:get_parent() --child interface
	return self._parent
end

function layer:set_parent(parent)
	if parent then
		parent:add_layer(self, self._layer_index)
	elseif self._parent then
		if self.hot then
			self.ui.hot_widget = false
		end
		if self.active then
			self.ui.active_widget = false
		end
		self._parent:remove_layer(self)
	end
end

layer._pos_parent = false

function layer:get_pos_parent() --child interface
	return self._pos_parent or self._parent
end

function layer:set_pos_parent(parent)
	if parent and parent.iswindow then
		parent = parent.view
	end
	if parent == self.parent then
		parent = false
	end
	self._pos_parent = parent
end

function layer:to_back()
	self.layer_index = 1
end

function layer:to_front()
	self.layer_index = 1/0
end

function layer:get_layer_index()
	if self.parent then
		return indexof(self, self.parent)
	else
		return self._layer_index
	end
end

function layer:move_layer(layer, index)
	local new_index = clamp(index, 1, #self)
	local old_index = indexof(layer, self)
	if old_index == new_index then return end
	table.remove(self, old_index)
	table.insert(self, new_index, layer)
	self:fire('layer_moved', new_index, old_index)
	layer:_set_layout_tags(new_index)
end

function layer:set_layer_index(index)
	if self.parent then
		self.parent:move_layer(self, index)
	else
		self._layer_index = index
	end
end

function layer:each_child(func)
	for _,layer in ipairs(self) do
		local ret = layer:each_child(func)
		if ret ~= nil then return ret end
		local ret = func(layer)
		if ret ~= nil then return ret end
	end
end

function layer:children()
	return coroutine.wrap(function()
		self:each_child(coroutine.yield)
	end)
end

function layer:add_layer(layer, index) --parent interface
	if layer._parent == self then return end
	if layer._parent then
		layer._parent:remove_layer(layer)
	end
	index = clamp(index or 1/0, 1, #self + 1)
	push(self, index, layer)
	layer._parent = self
	layer.window = self.window
	self:fire('layer_added', layer, index)
	layer:_update_enabled(layer.enabled)
end

function layer:remove_layer(layer) --parent interface
	assert(layer._parent == self)
	self:off({nil, layer})
	popval(self, layer)
	self:fire('layer_removed', layer)
	layer._parent = false
	layer.window = false
	layer:_update_enabled(layer.enabled)
end

function layer:_free_children()
	while #self > 0 do
		self[#self]:free()
	end
end
]]

--border geometry and drawing ------------------------------------------------

field layer.border_width_left   : num = 0
field layer.border_width_right  : num = 0
field layer.border_width_top    : num = 0
field layer.border_width_bottom : num = 0

field layer.corner_radius_top_left     : num = 0
field layer.corner_radius_top_right    : num = 0
field layer.corner_radius_bottom_left  : num = 0
field layer.corner_radius_bottom_right : num = 0

field layer.border_color_left   : color = 0
field layer.border_color_right  : color = 0
field layer.border_color_top    : color = 0
field layer.border_color_bottom : color = 0

field layer.border_dash: arr(double) --{on_width1, off_width1, ...}
field layer.border_dash_offset: int = 0

-- border stroke positioning relative to box edge.
-- -1..1 goes from inside to outside of box edge.
field layer.border_offset: num = -1

--draw rounded corners with a modified bezier for smoother line-to-arc
--transitions. kappa=1 uses circle arcs instead.
field layer.corner_radius_kappa: num = 1.2

--border edge widths relative to box rect at %-offset in border width.
--offset is in -1..1 where -1=inner edge, 0=center, 1=outer edge.
--returned widths are positive when inside and negative when outside box rect.
method layer:_border_edge_widths(offset: num): num4
	var o = self.border_offset + offset + 1
	var w1 = lerp(o, -1, 1, self.border_width_left,   0)
	var h1 = lerp(o, -1, 1, self.border_width_top,    0)
	var w2 = lerp(o, -1, 1, self.border_width_right,  0)
	var h2 = lerp(o, -1, 1, self.border_width_bottom, 0)
	--adjust overlapping widths by scaling them down proportionally.
	if w1 + w2 > self.w or h1 + h2 > self.h then
		var scale = min(self.w / (w1 + w2), self.h / (h1 + h2))
		w1 = w1 * scale
		h1 = h1 * scale
		w2 = w2 * scale
		h2 = h2 * scale
	end
	return w1, h1, w2, h2
end

method layer:border_pos(offset): num2
	local w, h = self:_border_edge_widths(offset)
	return w, h
end

--border rect at %-offset in border width.
method layer:border_rect(offset: num, size_offset: num): num4
	var w1, h1, w2, h2 = self:_border_edge_widths(offset)
	var w = self.w - w2 - w1
	var h = self.h - h2 - h1
	return box2d_offset(size_offset, w1, h1, w, h)
end

method layer:border_rect(offset: num): num4
	return self:border_rect(offset, 0)
end

function layer:get_inner_x() return self:border_rect(-1)._0 end
function layer:get_inner_y() return self:border_rect(-1)._1 end
function layer:get_inner_w() return self:border_rect(-1)._2 end
function layer:get_inner_h() return self:border_rect(-1)._3 end
function layer:get_outer_x() return self:border_rect( 1)._0 end
function layer:get_outer_y() return self:border_rect( 1)._1 end
function layer:get_outer_w() return self:border_rect( 1)._2 end
function layer:get_outer_h() return self:border_rect( 1)._3 end

--corner radius at pixel offset from the stroke's center on one dimension.
local terra offset_radius(r: num, o: num)
	return iif(r > 0, max(0, r + o), 0)
end

local num13 = {num, num, num, num, num, num, num, num, num, num, num, num, num}

--border rect at %-offset in border width, plus radii of rounded corners.
method layer:border_round_rect(offset: num, size_offset: num): num13

	var k = self.corner_radius_kappa

	var x1, y1, w, h = self:border_rect(0) --at stroke center
	var X1, Y1, W, H = self:border_rect(offset, size_offset) --at offset

	var x2, y2 = x1 + w, y1 + h
	var X2, Y2 = X1 + W, Y1 + H

	var r1 = self.corner_radius_top_left
	var r2 = self.corner_radius_top_right
	var r3 = self.corner_radius_bottom_right
	var r4 = self.corner_radius_bottom_left

	--offset the radii to preserve curvature at offset.
	var r1x = offset_radius(r1, x1-X1)
	var r1y = offset_radius(r1, y1-Y1)
	var r2x = offset_radius(r2, X2-x2)
	var r2y = offset_radius(r2, y1-Y1)
	var r3x = offset_radius(r3, X2-x2)
	var r3y = offset_radius(r3, Y2-y2)
	var r4x = offset_radius(r4, x1-X1)
	var r4y = offset_radius(r4, Y2-y2)

	--remove degenerate arcs.
	if r1x == 0 or r1y == 0 then r1x = 0; r1y = 0 end
	if r2x == 0 or r2y == 0 then r2x = 0; r2y = 0 end
	if r3x == 0 or r3y == 0 then r3x = 0; r3y = 0 end
	if r4x == 0 or r4y == 0 then r4x = 0; r4y = 0 end

	--adjust overlapping radii by scaling them down proportionally.
	var maxx = max(r1x + r2x, r3x + r4x)
	var maxy = max(r1y + r4y, r2y + r3y)
	if maxx > W or maxy > H then
		var scale = min(W / maxx, H / maxy)
		r1x = r1x * scale
		r1y = r1y * scale
		r2x = r2x * scale
		r2y = r2y * scale
		r3x = r3x * scale
		r3y = r3y * scale
		r4x = r4x * scale
		r4y = r4y * scale
	end

	return
		X1, Y1, W, H,
		r1x, r1y, r2x, r2y, r3x, r3y, r4x, r4y,
		k
end

method layer:border_round_rect(offset: num): num13
	return self:border_round_rect(offset, 0)
end

--De Casteljau split of a cubic bezier at time t (from path2d).
local terra bezier_split(first: bool, t: num,
	x1: num, y1: num, x2: num, y2: num, x3: num, y3: num, x4: num, y4: num
)
	var mt = 1-t
	var x12 = x1 * mt + x2 * t
	var y12 = y1 * mt + y2 * t
	var x23 = x2 * mt + x3 * t
	var y23 = y2 * mt + y3 * t
	var x34 = x3 * mt + x4 * t
	var y34 = y3 * mt + y4 * t
	var x123 = x12 * mt + x23 * t
	var y123 = y12 * mt + y23 * t
	var x234 = x23 * mt + x34 * t
	var y234 = y23 * mt + y34 * t
	var x1234 = x123 * mt + x234 * t
	var y1234 = y123 * mt + y234 * t
	if first then
		return x1, y1, x12, y12, x123, y123, x1234, y1234 --first curve
	else
		return x1234, y1234, x234, y234, x34, y34, x4, y4 --second curve
	end
end

local kappa = 4 / 3 * (sqrt(2) - 1)

--more-aesthetically-pleasing elliptic arc. only for 45deg and 90deg sweeps!
local terra bezier_qarc(cr: &cairo_t, cx: num, cy: num, rx: num, ry: num, q1: num, qlen: num, k: num)
	cr:save()
	cr:translate(cx, cy)
	cr:scale(rx / ry, 1)
	cr:rotate(floor(min(q1, q1 + qlen) - 2) * PI / 2)
	var r = ry
	var k = r * kappa * k
	var x1, y1, x2, y2, x3, y3, x4, y4 = 0, -r, k, -r, r, -k, r, 0
	if qlen < 0 then --reverse curve
		x1, y1, x2, y2, x3, y3, x4, y4 = x4, y4, x3, y3, x2, y2, x1, y1
		qlen = abs(qlen)
	end
	if qlen ~= 1 then
		assert(qlen == .5)
		var first = q1 == floor(q1)
		x1, y1, x2, y2, x3, y3, x4, y4 =
			bezier_split(first, qlen, x1, y1, x2, y2, x3, y3, x4, y4)
	end
	cr:line_to(x1, y1)
	cr:curve_to(x2, y2, x3, y3, x4, y4)
	cr:restore()
end

--draw a rounded corner: q1 is the quadrant starting top-left going clockwise.
--qlen is in 90deg units and can only be +/- .5 or 1 if k ~= 1.
method layer:corner_path(cr: &cairo_t, cx: num, cy: num, rx: num, ry: num, q1: num, qlen: num, k: num)
	if rx == 0 or ry == 0 then --null arcs need a line to the first endpoint
		assert(rx == 0 and ry == 0)
		cr:line_to(cx, cy)
	elseif k == 1 then --geometrically-correct elliptic arc
		var q2 = q1 + qlen
		var a1 = (q1 - 3) * PI / 2
		var a2 = (q2 - 3) * PI / 2
		if a1 < a2 then
			cr:elliptic_arc(cx, cy, rx, ry, 0, a1, a2)
		else
			cr:elliptic_arc_negative(cx, cy, rx, ry, 0, a1, a2)
		end
	else
		bezier_qarc(cr, cx, cy, rx, ry, q1, qlen, k)
	end
end

method layer:border_line_to(cr: &cairo_t, x: num, y: num, q: num) end --stub (used by tablist)

--trace the border contour path at offset.
--offset is in -1..1 where -1=inner edge, 0=center, 1=outer edge.
method layer:border_path(cr: &cairo_t, offset: num, size_offset: num)
	var x1, y1, w, h, r1x, r1y, r2x, r2y, r3x, r3y, r4x, r4y, k =
		self:border_round_rect(offset, size_offset)
	var x2, y2 = x1 + w, y1 + h
	cr:move_to(x1, y1+r1y)
	self:corner_path    (cr, x1+r1x, y1+r1y, r1x, r1y, 1, 1, k) --tl
	self:border_line_to (cr, x2-r2x, y1, 1)
	self:corner_path    (cr, x2-r2x, y1+r2y, r2x, r2y, 2, 1, k) --tr
	self:border_line_to (cr, x2, y2-r3y, 2)
	self:corner_path    (cr, x2-r3x, y2-r3y, r3x, r3y, 3, 1, k) --br
	self:border_line_to (cr, x1+r4x, y2, 3)
	self:corner_path    (cr, x1+r4x, y2-r4y, r4x, r4y, 4, 1, k) --bl
	self:border_line_to (cr, x1, y1+r1y, 4)
	cr:close_path()
end

method layer:border_path(cr: &cairo_t, offset: num)
	return self:border_path(cr, offset)
end

method layer:border_visible(): bool
	return
		   self.border_width_left ~= 0
		or self.border_width_top ~= 0
		or self.border_width_right ~= 0
		or self.border_width_bottom ~= 0
end

method layer:draw_border(cr: &cairo_t)
	if not self:border_visible() then return end

	--seamless drawing when all side colors are the same.
	if self.border_color_left == self.border_color_top
		and self.border_color_left == self.border_color_right
		and self.border_color_left == self.border_color_bottom
	then
		cr:new_path()
		cr:rgba(self.border_color_bottom)
		if self.border_width_left == self.border_width_top
			and self.border_width_left == self.border_width_right
			and self.border_width_left == self.border_width_bottom
		then --stroke-based method (doesn't require path offseting; supports dashing)
			self:border_path(cr, 0)
			cr:line_width(self.border_width_left)
			if self.border_dash.len > 0 then
				cr:dash(self.border_dash.elements, self.border_dash.len, self.border_dash_offset)
			end
			cr:stroke()
		else --fill-based method (requires path offsetting; supports patterns)
			cr:fill_rule(CAIRO_FILL_RULE_EVEN_ODD)
			self:border_path(cr, -1)
			self:border_path(cr, 1)
			cr:fill()
		end
		return
	end

	--complicated drawing of each side separately.
	--still shows seams on adjacent sides of the same color.
	var x1, y1, w, h, r1x, r1y, r2x, r2y, r3x, r3y, r4x, r4y, k =
		self:border_round_rect(-1)
	var X1, Y1, W, H, R1X, R1Y, R2X, R2Y, R3X, R3Y, R4X, R4Y, K =
		self:border_round_rect(1)

	var x2, y2 = x1 + w, y1 + h
	var X2, Y2 = X1 + W, Y1 + H

	if self.border_color_left.a > 0 then
		cr:new_path()
		cr:move_to(x1, y1+r1y)
		self:corner_path(cr, x1+r1x, y1+r1y, r1x, r1y, 1, .5, k)
		self:corner_path(cr, X1+R1X, Y1+R1Y, R1X, R1Y, 1.5, -.5, K)
		cr:line_to(X1, Y2-R4Y)
		self:corner_path(cr, X1+R4X, Y2-R4Y, R4X, R4Y, 5, -.5, K)
		self:corner_path(cr, x1+r4x, y2-r4y, r4x, r4y, 4.5, .5, k)
		cr:close_path()
		cr:rgba(self.border_color_left)
		cr:fill()
	end

	if self.border_color_top.a > 0 then
		cr:new_path()
		cr:move_to(x2-r2x, y1)
		self:corner_path(cr, x2-r2x, y1+r2y, r2x, r2y, 2, .5, k)
		self:corner_path(cr, X2-R2X, Y1+R2Y, R2X, R2Y, 2.5, -.5, K)
		cr:line_to(X1+R1X, Y1)
		self:corner_path(cr, X1+R1X, Y1+R1Y, R1X, R1Y, 2, -.5, K)
		self:corner_path(cr, x1+r1x, y1+r1y, r1x, r1y, 1.5, .5, k)
		cr:close_path()
		cr:rgba(self.border_color_top)
		cr:fill()
	end

	if self.border_color_right.a > 0 then
		cr:new_path()
		cr:move_to(x2, y2-r3y)
		self:corner_path(cr, x2-r3x, y2-r3y, r3x, r3y, 3, .5, k)
		self:corner_path(cr, X2-R3X, Y2-R3Y, R3X, R3Y, 3.5, -.5, K)
		cr:line_to(X2, Y1+R2Y)
		self:corner_path(cr, X2-R2X, Y1+R2Y, R2X, R2Y, 3, -.5, K)
		self:corner_path(cr, x2-r2x, y1+r2y, r2x, r2y, 2.5, .5, k)
		cr:close_path()
		cr:rgba(self.border_color_right)
		cr:fill()
	end

	if self.border_color_bottom.a > 0 then
		cr:new_path()
		cr:move_to(x1+r4x, y2)
		self:corner_path(cr, x1+r4x, y2-r4y, r4x, r4y, 4, .5, k)
		self:corner_path(cr, X1+R4X, Y2-R4Y, R4X, R4Y, 4.5, -.5, K)
		cr:line_to(X2-R3X, Y2)
		self:corner_path(cr, X2-R3X, Y2-R3Y, R3X, R3Y, 4, -.5, K)
		self:corner_path(cr, x2-r3x, y2-r3y, r3x, r3y, 3.5, .5, k)
		cr:close_path()
		cr:rgba(self.border_color_bottom)
		cr:fill()
	end
end

--content-box geometry, drawing and hit testing ------------------------------

field layer.padding_left   : num = 0
field layer.padding_right  : num = 0
field layer.padding_top    : num = 0
field layer.padding_bottom : num = 0

method layer:get_pw(): num
	return self.padding_left + self.padding_right
end
method layer:get_ph(): num
	return self.padding_top + self.padding_bottom
end
method layer:get_pw1(): num return self.padding_left   end
method layer:get_ph1(): num return self.padding_top    end
method layer:get_pw2(): num return self.padding_right  end
method layer:get_ph2(): num return self.padding_bottom end

method layer:padding_pos(): num2 --in box space
	var px = self.padding_left
	var py = self.padding_top
	return px, py
end

method layer:padding_size(): num2
	var px1 = self.padding_left
	var py1 = self.padding_top
	var px2 = self.padding_right
	var py2 = self.padding_bottom
	return
		self.w - (px1 + px2),
		self.h - (py1 + py2)
end

method layer:client_size(): num2
	return self:padding_size()
end

method layer:padding_rect(): num4 --in box space
	var px1 = self.padding_left
	var py1 = self.padding_top
	var px2 = self.padding_right
	var py2 = self.padding_bottom
	return
		px1, py1,
		self.w - (px1 + px2),
		self.h - (py1 + py2)
end

method layer:client_rect(): num4 --in content space
	var w, h = self:padding_size()
	return 0, 0, w, h
end

method layer:get_cw(): num
	var px1 = self.padding_left
	var px2 = self.padding_right
	return
		self.w - (px1 + px2)
end

method layer:get_ch(): num
	var py1 = self.padding_top
	var py2 = self.padding_bottom
	return
		self.h - (py1 + py2)
end

method layer:set_cw(cw: num) self.w = cw + (self.w - self.cw) end
method layer:set_ch(ch: num) self.h = ch + (self.h - self.ch) end

--convert point from own box space to own content space.
method layer:to_content(x: num, y: num): num2
	var px, py = self:padding_pos()
	return x - px, y - py
end

--content point from own content space to own box space.
method layer:from_content(x: num, y: num): num2
	var px, py = self:padding_pos()
	return px + x, py + y
end

--layers geometry, drawing and hit testing -----------------------------------

--[[
method layer:children_bbox(strict: bool)
	local x, y, w, h = 0, 0, 0, 0
	for _,layer in self.children do
		x, y, w, h = box2d.bounding_box(x, y, w, h,
			layer:bbox(strict))
	end
	return x, y, w, h
end

method layer:draw_children(cr: &cairo_t) --called in content space
	for i,e in self.children do
		e:draw(cr)
	end
end

--called in content space
method layer:hit_test_children(x: num, y: num, reason: int): {&layer, int}
	for i,e in self.children:backwards() do
		var widget, area = e:hit_test(x, y, reason)
		if widget ~= nil then
			return widget, area
		end
	end
	return nil, 0
end
]]

if not ... then

terra test()
	var e = layer(nil)
	--var e1 = layer(nil)
	--e:add_layer(e1)
end
test()

end

return layer