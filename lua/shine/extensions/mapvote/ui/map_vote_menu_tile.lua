--[[
	A simple tile button used to display a map, its number of votes, and whether
	it has been chosen.

	On hover, the overview of the map is loaded and displayed.
]]

local Pi = math.pi
local StringStartsWith = string.StartsWith
local TableShallowMerge = table.ShallowMerge

local Locale = Shine.Locale
local SGUI = Shine.GUI
local Controls = SGUI.Controls
local Units = SGUI.Layout.Units

local Binder = require "shine/lib/gui/binding/binder"
local MapDataRepository = require "shine/extensions/mapvote/map_data_repository"

local MapTile = SGUI:DefineControl( "MapTile", "Button" )

SGUI.AddProperty( MapTile, "NumVotes", 0 )
SGUI.AddProperty( MapTile, "OverviewTexture" )
SGUI.AddProperty( MapTile, "PreviewTexture" )
SGUI.AddProperty( MapTile, "Selected", false )

SGUI.AddBoundProperty( MapTile, "Text", "MapNameLabel:SetText" )
SGUI.AddBoundProperty( MapTile, "TextColour", { "MapNameLabel:SetColour", "VoteCounterLabel:SetColour" } )
SGUI.AddBoundProperty( MapTile, "MapNameAutoFont", "MapNameLabel:SetAutoFont" )
SGUI.AddBoundProperty( MapTile, "VoteCounterAutoFont", "VoteCounterLabel:SetAutoFont" )

function MapTile:Initialise()
	Controls.Button.Initialise( self )

	self:SetHorizontal( false )
	self:SetHighlightOnMouseOver( false )

	TableShallowMerge( SGUI:BuildTree( self, {
		{
			Type = "Layout",
			Class = "Vertical",
			Props = {
				Fill = false,
				AutoSize = Units.UnitVector( Units.Percentage( 100 ), Units.Percentage( 100 ) )
			},
			Children = {
				{
					Class = "Row",
					Props = {
						AutoSize = Units.UnitVector( Units.Percentage( 100 ), Units.Auto() ),
						StyleName = "MapTileHeader"
					},
					Children = {
						{
							ID = "MapNameLabel",
							Class = "Label",
							Props = {
								Alignment = SGUI.LayoutAlignment.CENTRE,
								CrossAxisAlignment = SGUI.LayoutAlignment.CENTRE,
								StyleName = "MapTileLabel"
							}
						}
					}
				},
				{
					ID = "PreviewImage",
					Class = "Image",
					Props = {
						Fill = true,
						IsVisible = false,
						InheritsParentAlpha = true,
						StyleName = "PreviewImage"
					}
				},
				{
					ID = "LoadingIndicatorContainer",
					Class = "Row",
					Props = {
						Fill = true,
						StyleName = "LoadingIndicatorContainer"
					},
					Children = {
						{
							ID = "LoadingIndicator",
							Class = "ProgressWheel",
							Props = {
								Fraction = 0.75,
								Alignment = SGUI.LayoutAlignment.CENTRE,
								CrossAxisAlignment = SGUI.LayoutAlignment.CENTRE,
								-- TODO: Add a way to make height == width as a unit
								AutoSize = Units.UnitVector( Units.HighResScaled( 64 ), Units.HighResScaled( 64 ) )
							}
						}
					}
				},
				{
					Class = "Row",
					Props = {
						AutoSize = Units.UnitVector( Units.Percentage( 100 ), Units.Auto() ),
						StyleName = "MapTileHeader"
					},
					Children = {
						{
							ID = "VoteCounterLabel",
							Class = "Label",
							Props = {
								Alignment = SGUI.LayoutAlignment.CENTRE,
								CrossAxisAlignment = SGUI.LayoutAlignment.CENTRE,
								StyleName = "MapTileLabel"
							}
						}
					}
				}
			}
		}

	} ), self )

	Binder():FromElement( self, "NumVotes" )
		:ToElement( self.VoteCounterLabel, "Text", {
			Transformer = function( NumVotes )
				return Locale:GetInterpolatedPhrase( "mapvote", "VOTE_COUNTER", {
					NumVotes = NumVotes
				} )
			end
		} ):BindProperty()
	Binder():FromElement( self, "Selected" )
		:ToElement( self, "Icon", {
			Transformer = function( Selected )
				if Selected then
					return SGUI.Icons.Ionicons.Checkmark,
						SGUI.FontManager.GetHighResFont( SGUI.FontFamilies.Ionicons, 64 )
				end
				return nil
			end
		} ):BindProperty()

	-- TODO: Add OnPreviewTextureFailed method, and use it to set a placeholder texture.
	Binder():FromElement( self, "PreviewTexture" )
		:ToElement( self.PreviewImage, "Texture" )
		:ToElement( self.PreviewImage, "TextureCoordinates", {
			Filter = function( Texture )
				-- Apply only to mounted loading screens textures (assumed vanilla map).
				return Texture ~= nil and StringStartsWith( Texture, "screens/" )
			end,
			Transformer = function( Texture )
				-- Magic numbers that seem to work well. Thankfully each loading screen seems to follow a standard
				-- template with the same position for the map name + minimap.
				return 95 / 1920, 205 / 1200, ( 95 + 1024 ) / 1920, ( 205 + 768 ) / 1200
			end
		} )
		:BindProperty()

	self.PreviewImage:AddPropertyChangeListener( "Texture", function( Texture )
		if not Texture then return end

		if SGUI.IsValid( self.LoadingIndicatorContainer ) then
			self.LoadingIndicatorContainer:Destroy()
			self.LoadingIndicatorContainer = nil
			self.LoadingIndicator = nil
		end

		self.PreviewImage:SetIsVisible( true )

		if StringStartsWith( Texture, "screens/" ) then
			-- Image was already mounted (thus there was no delay), display immediately.
			return
		end

		-- Fade the image in after loading.
		self.PreviewImage:AlphaTo( nil, 0, 1, 0, 0.3 )
	end )
end

function MapTile:OnHover()
	if self.OverviewTexture then
		if not SGUI.IsValid( self.OverviewImage ) then
			local Elements = SGUI:BuildTree( self.PreviewImage, {
				{
					Type = "Layout",
					Class = "Vertical",
					Children = {
						{
							ID = "OverviewImage",
							Class = "Image",
							Props = {
								Colour = Colour( 1, 1, 1, 0 ),
								Texture = self.OverviewTexture,
								Fill = true
							}
						}
					}
				}
			} )
			self.OverviewImage = Elements.OverviewImage
			self.PreviewImage:InvalidateLayout( true )
		end

		self.OverviewImage:AlphaTo( nil, nil, 1, 0.3 )

		return
	end

	MapDataRepository.GetOverviewImage( self.ModID, self.MapName, function( MapName, TextureName, Err )
		if Err then
			return
		end

		self:SetOverviewTexture( TextureName )

		if not self.MouseHovered then return end

		self:OnHover()
	end )
end

function MapTile:OnLoseHover()
	if SGUI.IsValid( self.OverviewImage ) then
		self.OverviewImage:AlphaTo( nil, nil, 0, 0.3, function()
			self.PreviewImage:SetLayout( nil )
			self.OverviewImage:Destroy()
			self.OverviewImage = nil
		end )
	end
end

function MapTile:DoClick()
	self.Parent:SetSelectedMap( self.MapName )
	return true
end

function MapTile:SetMap( ModID, MapName )
	self.ModID = ModID
	self.MapName = MapName
end

function MapTile:OnPreviewTextureFailed( Err )
	self:SetPreviewTexture( "ui/shine/unknown_map.tga" )
end

function MapTile:Think( DeltaTime )
	Controls.Button.Think( self, DeltaTime )

	if self.LoadingIndicator then
		self.LoadingIndicator:SetAngle( self.LoadingIndicator:GetAngle() - DeltaTime * Pi * 2 )
	end
end

return MapTile
