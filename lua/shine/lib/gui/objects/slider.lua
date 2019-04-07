--[[
	Number slider control.
]]

local SGUI = Shine.GUI

local Clamp = math.Clamp
local Round = math.Round
local tostring = tostring
local type = type

local Slider = {}

local DefaultHandleSize = Vector2( 10, 32 )
local DefaultLineSize = Vector2( 250, 5 )
local DefaultUnfilledLineSize = Vector2( 0, 5 )
local DefaultSize = Vector2( 250, 32 )
local Padding = Vector2( 20, 0 )

local LinePos = Vector2( 0, -2.5 )
local UnfilledLinePos = Vector2( 250, -2.5 )

local Clear = Colour( 0, 0, 0, 0 )

local IsType = Shine.IsType

function Slider:Initialise()
	self.BaseClass.Initialise( self )

	local Background = self:MakeGUIItem()
	Background:SetSize( DefaultSize )
	Background:SetColor( Clear )

	self.Background = Background

	local Line = self:MakeGUIItem()
	Line:SetAnchor( GUIItem.Left, GUIItem.Center )
	Line:SetSize( DefaultLineSize )
	Line:SetPosition( LinePos )

	Background:AddChild( Line )

	self.Line = Line

	local UnfilledLine = self:MakeGUIItem()
	UnfilledLine:SetAnchor( GUIItem.Left, GUIItem.Center )
	UnfilledLine:SetSize( DefaultUnfilledLineSize )
	UnfilledLine:SetPosition( UnfilledLinePos )

	Background:AddChild( UnfilledLine )

	self.DarkLine = UnfilledLine

	local Handle = self:MakeGUIItem()
	Handle:SetAnchor( GUIItem.Left, GUIItem.Top )
	Handle:SetSize( DefaultHandleSize )

	Background:AddChild( Handle )

	self.Handle = Handle

	local Label = SGUI:Create( "Label", self )
	Label:SetAnchor( GUIItem.Right, GUIItem.Center )
	Label:SetTextAlignmentY( GUIItem.Align_Center )
	Label:SetPos( Padding )

	self.Label = Label
	self.Width = DefaultSize.x

	self.Fraction = 0
	self.Min = 0
	self.Max = 100
	self.Range = 100
	self.Value = 0
	self.Decimals = 0
	self.LineHeightMultiplier = 0.25

	self.HandleSize = Vector2( 10, 32 )
	self.HandlePos = Vector2( 0, 0 )
	self.LineSize = Vector2( 250, 5 )
	self.DarkLineSize = Vector2( 0, 5 )
	self.DarkLinePos = Vector2( 250, -2.5 )
end

function Slider:SetupStencil()
	self.BaseClass.SetupStencil( self )

	self.Handle:SetInheritsParentStencilSettings( true )
	self.Line:SetInheritsParentStencilSettings( true )
	self.DarkLine:SetInheritsParentStencilSettings( true )
	self.Label.Label:SetInheritsParentStencilSettings( true )
end

function Slider:SizeLines()
	if not self.Width or not self.Height then return end

	local LineWidth = self.Width * self.Fraction
	self.LineSize.x = LineWidth
	self.LineSize.y = self.Height * self.LineHeightMultiplier
	self.Line:SetSize( self.LineSize )

	local CurrentLinePos = Vector2( 0, -self.LineSize.y * 0.5 )
	self.Line:SetPosition( CurrentLinePos )

	self.DarkLinePos.x = LineWidth
	self.DarkLinePos.y = CurrentLinePos.y
	self.DarkLine:SetPosition( self.DarkLinePos )

	self.DarkLineSize.x = self.Width * ( 1 - self.Fraction )
	self.DarkLineSize.y = self.LineSize.y
	self.DarkLine:SetSize( self.DarkLineSize )

	self.HandleSize.y = self.Height
	self.Handle:SetSize( self.HandleSize )
end

function Slider:SetLineHeightMultiplier( Multiplier )
	self.LineHeightMultiplier = Multiplier
	self:SizeLines()
end

function Slider:SetHandleWidth( Width )
	self.HandleSize.x = Width
	self.Handle:SetSize( self.HandleSize )
end

function Slider:SetSize( Size )
	self.BaseClass.SetSize( self, Size )

	self.Height = Size.y
	self.Width = Size.x

	self:SetValue( self.Value )
end

SGUI.AddBoundProperty( Slider, "Font", "Label" )
SGUI.AddBoundProperty( Slider, "TextColour", "Label:SetColour" )
SGUI.AddBoundProperty( Slider, "TextScale", "Label" )
SGUI.AddBoundProperty( Slider, "HandleColour", "Handle:SetColor" )
SGUI.AddBoundProperty( Slider, "LineColour", "Line:SetColor" )
SGUI.AddBoundProperty( Slider, "DarkLineColour", "DarkLine:SetColor" )

function Slider:SetPadding( Value )
	self.Label:SetPos( Vector2( Value, 0 ) )
end

--[[
	Sets the slider's position by value.
]]
function Slider:SetValue( Value )
	if not IsType( Value, "number" ) then return end

	self.Value = Clamp( Round( Value, self.Decimals ), self.Min, self.Max )

	self.Fraction = Clamp( ( Value - self.Min ) / self.Range, 0, 1 )
	self.HandlePos.x = self.Width * self.Fraction

	self.Handle:SetPosition( self.HandlePos )
	self.Label:SetText( tostring( self.Value ) )
	self:SizeLines()
end

--[[
	Sets the slider's position by fraction.
]]
function Slider:SetFraction( Fraction )
	self.Value = Clamp( Round( self.Min + ( Fraction * self.Range ), self.Decimals ),
		self.Min, self.Max )
	self.Fraction = Clamp( ( self.Value - self.Min ) / self.Range, 0, 1 )

	self.HandlePos.x = self.Width * self.Fraction
	self.Handle:SetPosition( self.HandlePos )

	self.Label:SetText( tostring( self.Value ) )
	self:SizeLines()
end

function Slider:ChangeValue( Value )
	local OldValue = self.Value

	self:SetValue( Value )

	if OldValue ~= self.Value then
		self:OnSlide( self.Value )
		self:OnValueChanged( self.Value )
	end
end

function Slider:GetValue()
	return self.Value
end

SGUI.AddProperty( Slider, "Decimals" )

--[[
	Sets the bounds of the slider.
]]
function Slider:SetBounds( Min, Max )
	self.Min = Min
	self.Max = Max

	self.Range = Max - Min

	--Update our slider value to clamp it inside the new bounds if needed.
	self:SetValue( self.Value )
end

function Slider:PlayerKeyPress( Key, Down )
	if not self:MouseIn( self.Background ) then return end

	if Key == InputKey.Left or Key == InputKey.Down then
		self:ChangeValue( self:GetValue() - 1 * 10 ^ -self.Decimals )
		return true
	end

	if Key == InputKey.Right or Key == InputKey.Up then
		self:ChangeValue( self:GetValue() + 1 * 10 ^ -self.Decimals )
		return true
	end
end

local GetCursorPos
local LineMult = Vector2( 1, 0.5 )

function Slider:OnMouseDown( Key )
	if Key ~= InputKey.MouseButton0 then return end
	if not self:MouseIn( self.Handle, 1.25 ) then
		if self:MouseIn( self.Background, LineMult ) then
			self.ClickingLine = true

			return true, self
		end

		return
	end

	GetCursorPos = GetCursorPos or Client.GetCursorPosScreen

	local X, Y = GetCursorPos()

	self.Dragging = true

	self.DragStart = X
	self.StartingPos = self.Handle:GetPosition()

	self.CurPos = Vector2( self.StartingPos.x, 0 )

	return true, self
end

function Slider:OnMouseUp( Key )
	if Key ~= InputKey.MouseButton0 then return end

	if self.ClickingLine then
		self.ClickingLine = nil

		local In, X, Y = self:MouseIn( self.Background, LineMult )
		if not In then return end

		local Fraction = X / self.Width
		self:SetFraction( Fraction )
	else
		self.Dragging = false
	end

	self:OnValueChanged( self:GetValue() )

	return true
end

function Slider:OnMouseMove( Down )
	if not Down then return end
	if not self.Dragging then return end

	local X, Y = GetCursorPos()

	local Diff = X - self.DragStart

	self.CurPos.x = Clamp( self.StartingPos.x + Diff, 0, self.Width )

	local OldValue = self.Value
	self:SetFraction( self.CurPos.x / self.Width )

	if OldValue ~= self.Value then
		self:OnSlide( self.Value )
	end
end

--[[
	Called when the slider has stopped being moved.
]]
function Slider:OnValueChanged( Value )

end

--[[
	Called as the slider is being moved.
]]
function Slider:OnSlide( Value )

end

SGUI:Register( "Slider", Slider )
