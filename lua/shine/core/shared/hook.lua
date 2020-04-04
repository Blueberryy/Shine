--[[
	Shine internal hook system.
]]

local CodeGen = require "shine/lib/codegen"

local Shine = Shine

local Clamp = math.Clamp
local DebugGetInfo = debug.getinfo
local DebugGetMetaTable = debug.getmetatable
local DebugSetUpValue = debug.setupvalue
local Floor = math.floor
local Huge = math.huge
local IsCallable = Shine.IsCallable
local IsType = Shine.IsType
local Max = math.max
local ReplaceMethod = Shine.ReplaceClassMethod
local select = select
local StringExplode = string.Explode
local StringFormat = string.format
local xpcall = xpcall

local LinkedList = Shine.LinkedList

local Hook = {}
Shine.Hook = Hook

-- A unique identifier for the callback that calls plugin hooks.
local ExtensionIndex = setmetatable( {}, { __tostring = function() return "CallExtensionEvent" end } )

-- A mapping of event -> hook index -> hook node.
local HookNodes = {}
-- A mapping of event -> hook index -> hook callback (for external use).
local HooksByEventAndIndex = {}

local OnError = Shine.BuildErrorHandler( "Hook error" )
local Hooks
do
	-- Use callable tables to avoid creating closures during hook calls.
	-- This helps to avoid LuaJIT blacklisting the hook call/broadcast functions.
	local PluginCaller = {
		__call = function( self, ... )
			return Shine:CallExtensionEvent( self[ 1 ], OnError, ... )
		end,
		__tostring = function( self )
			return StringFormat( "CallExtensionEvent - %s", self[ 1 ] )
		end
	}
	local PluginBroadcaster = {
		__call = function( self, ... )
			return Shine:BroadcastExtensionEvent( self[ 1 ], OnError, ... )
		end,
		__tostring = function( self )
			return StringFormat( "BroadcastExtensionEvent - %s", self[ 1 ] )
		end
	}

	Hooks = setmetatable( {}, {
		-- On first call/addition of an event, setup a default hook to call the event on extensions.
		__index = function( self, Event )
			local HooksByIndex = LinkedList()
			local Node = HooksByIndex:Add( {
				-- This emulates the old behaviour, placing the event between -20 and -19.
				-- No client of the public API can set non-integer priorities.
				Priority = -19.5,
				Callback = setmetatable( { Event }, PluginCaller ),
				BroadcastCallback = setmetatable( { Event }, PluginBroadcaster ),
				Index = ExtensionIndex
			} )

			HookNodes[ Event ] = {
				[ ExtensionIndex ] = Node
			}
			HooksByEventAndIndex[ Event ] = {
				[ ExtensionIndex ] = Node.Value.Callback
			}

			-- Save the list on the table to avoid invoking this again.
			self[ Event ] = HooksByIndex

			return HooksByIndex
		end
	} )
end

-- Sort nodes by priority. Equal priority nodes will be placed in insertion order
-- as the linked list will insert before the first node that is strictly after the
-- one being inserted (as opposed to before the first node that is not strictly before).
local function NodeComparator( A, B )
	return A.Priority < B.Priority
end

--[[
	Removes a function from Shine's internal hook system.

	It is generally not a good idea to remove hooks mid-call, except for the
	hook currently being executed.

	Inputs: Event, unique identifier.
]]
local function Remove( Event, Index )
	local Node = HookNodes[ Event ] and HookNodes[ Event ][ Index ]
	if not Node then return end

	HookNodes[ Event ][ Index ] = nil
	HooksByEventAndIndex[ Event ][ Index ] = nil

	-- The linked list allows this removal to be trivial.
	local Callbacks = Hooks[ Event ]
	Callbacks:Remove( Node )
end
Hook.Remove = Remove

local MAX_PRIORITY = -20
local DEFAULT_PRIORITY = 0
local MIN_PRIORITY = 20

Hook.MAX_PRIORITY = MAX_PRIORITY
Hook.DEFAULT_PRIORITY = DEFAULT_PRIORITY
Hook.MIN_PRIORITY = MIN_PRIORITY

--[[
	Adds a function to Shine's internal hook system.

	Ordering is defined by the priority, with lower values being called before higher
	values. For equal priorities, insertion order is respected.

	Inputs: Event to hook into, unique identifier, function to run, optional priority.
]]
local function Add( Event, Index, Function, Priority )
	Shine.AssertAtLevel( Event ~= nil, "Event identifier must not be nil!", 3 )

	-- If no key is provided, use the given function as the key.
	if ( Function == nil or IsType( Function, "number" ) ) and IsCallable( Index ) then
		Priority = Function
		Function = Index
	end

	Shine.AssertAtLevel( Index ~= nil, "Index must not be nil!", 3 )
	Shine.AssertAtLevel( IsCallable( Function ), "Function must be callable!", 3 )
	if Priority ~= nil then
		Shine.TypeCheck( Priority, "number", 4, "Add" )
	end

	Priority = Clamp( Floor( Priority or DEFAULT_PRIORITY ), MAX_PRIORITY, MIN_PRIORITY )

	-- If this index has already been used, replace it.
	local Nodes = HookNodes[ Event ]
	if Nodes and Nodes[ Index ] then
		Remove( Event, Index )
	end

	-- Maintain the order by inserting into the correct position in the
	-- list of hooks upfront.
	local Callbacks = Hooks[ Event ]
	local Node = Callbacks:InsertByComparing( {
		Priority = Priority,
		Index = Index,
		Callback = Function,
		BroadcastCallback = Function
	}, NodeComparator )

	-- Remember this node for later removal.
	HookNodes[ Event ][ Index ] = Node
	HooksByEventAndIndex[ Event ][ Index ] = Function
end
Hook.Add = Add

-- Placeholder until the extensions file is loaded.
if not Shine.CallExtensionEvent then
	Shine.CallExtensionEvent = function() end
end

if not Shine.BroadcastExtensionEvent then
	Shine.BroadcastExtensionEvent = function() end
end

local Call
do
	-- See the comment in codegen.lua for the reasoning of this seemingly bizarre way of calling hooks.
	-- In a nutshell, it's to avoid LuaJIT traces aborting with NYI when handling varargs.
	local Callers = CodeGen.MakeFunctionGenerator( {
		Template = [[local Shine, Hooks, OnError, Remove, ExtensionIndex = ...
		return function( Event{Arguments} )
			local Callbacks = Hooks[ Event ]

			for Node in Callbacks:IterateNodes() do
				local Entry = Node.Value
				local Success, a, b, c, d, e, f = xpcall( Entry.Callback, OnError{Arguments} )
				if not Success then
					-- If the error came from calling extension events, don't remove the hook
					-- (though it should never happen).
					if Entry.Index ~= ExtensionIndex then
						Shine:DebugPrint( "[Hook Error] %s hook '%s' failed, removing.",
							true, Event, Entry.Index )

						Remove( Event, Entry.Index )
					end
				elseif a ~= nil then
					return a, b, c, d, e, f
				end
			end
		end]],
		ChunkName = "@lua/shine/core/shared/hook.lua/Call",
		-- This should equal the largest number of arguments seen by a hook to avoid lazy-generation which can impact
		-- compilation results.
		InitialSize = 10,
		Args = { Shine, Hooks, OnError, Remove, ExtensionIndex },
		OnFunctionGenerated = function( NumArguments, Caller )
			Hook[ StringFormat( "CallWith%dArg%s", NumArguments, NumArguments == 1 and "" or "s" ) ] = Caller
		end
	} )

	--[[
		Calls an internal Shine hook.
		Inputs: Event name, arguments to pass.
	]]
	Call = function( Event, ... )
		-- LuaJIT happily compiles this despite it passing down a vararg, which lets us avoid having to go crazy with
		-- special case CallWithXArgs everywhere. The performance difference between this and using the specific
		-- variation is negligible.
		return Callers[ select( "#", ... ) ]( Event, ... )
	end
end
Hook.Call = Call

local Broadcast
do
	local Broadcasters = CodeGen.MakeFunctionGenerator( {
		Template = [[local Shine, Hooks, OnError, Remove, ExtensionIndex = ...
		return function( Event{Arguments} )
			local Callbacks = Hooks[ Event ]

			for Node in Callbacks:IterateNodes() do
				local Entry = Node.Value
				local Success = xpcall( Entry.BroadcastCallback, OnError{Arguments} )
				if not Success then
					-- If the error came from calling extension events, don't remove the hook
					-- (though it should never happen).
					if Entry.Index ~= ExtensionIndex then
						Shine:DebugPrint( "[Hook Error] %s hook '%s' failed, removing.",
							true, Event, Entry.Index )

						Remove( Event, Entry.Index )
					end
				end
			end
		end]],
		ChunkName = "@lua/shine/core/shared/hook.lua/Broadcast",
		InitialSize = 10,
		Args = { Shine, Hooks, OnError, Remove, ExtensionIndex },
		OnFunctionGenerated = function( NumArguments, Caller )
			Hook[ StringFormat( "BroadcastWith%dArg%s", NumArguments, NumArguments == 1 and "" or "s" ) ] = Caller
		end
	} )

	--[[
		Broadcasts an internal Shine hook, ignoring return values from callbacks.

		This always calls every added callback.

		Inputs: Event name, arguments to pass.
	]]
	Broadcast = function( Event, ... )
		return Broadcasters[ select( "#", ... ) ]( Event, ... )
	end
end
Hook.Broadcast = Broadcast

--[[
	Clears all hooks for the given event.
	This is called by CallOnce once it has invoked all hooks.
]]
local function ClearHooks( Event )
	Hooks[ Event ] = nil
	HooksByEventAndIndex[ Event ] = nil
	HookNodes[ Event ] = nil
end
Hook.Clear = ClearHooks

--[[
	Calls the given event, then clears all hooks for it.
]]
local function CallOnce( Event, ... )
	local a, b, c, d, e, f = Call( Event, ... )

	ClearHooks( Event )

	return a, b, c, d, e, f
end
Hook.CallOnce = CallOnce

local function BroadcastOnce( Event, ... )
	Broadcast( Event, ... )
	ClearHooks( Event )
end
Hook.BroadcastOnce = BroadcastOnce

function Hook.GetTable()
	return HooksByEventAndIndex
end

local function GetNumArguments( Func )
	local Offset = 0
	if IsType( Func, "table" ) then
		-- Handle callable tables here too.
		local Meta = DebugGetMetaTable( Func )
		if Meta and IsType( Meta.__call, "function" ) then
			Func = Meta.__call
			-- __call has a self argument which isn't seen by the caller.
			Offset = 1
		else
			return Huge
		end
	end

	local Info = IsType( Func, "function" ) and DebugGetInfo( Func )
	if not Info or Info.isvararg then
		return Huge
	end

	return Max( ( Info.nparams or Huge ) - Offset, 0 )
end

--[[
	Replaces the given method in the given class with ReplacementFunc.

	Inputs: Class name, method name, replacement function.
	Output: Original function.
]]
local function AddClassHook( ReplacementFuncTemplate, HookName, Caller, Class, Method )
	local OldFunc = Shine.GetClassMethod( Class, Method )
	if not OldFunc then
		-- For backwards compatibility's sake, just print a warning here and do nothing.
		Print( "[Shine] [Warn] Attempted to hook class/method %s:%s() which does not exist!", Class, Method )
		return nil
	end

	local NumArguments = GetNumArguments( OldFunc )
	local ReplacementFunc
	if not IsType( ReplacementFuncTemplate, "string" ) then
		ReplacementFunc = CodeGen.GenerateFunctionWithArguments(
			[[local OldFunc, ReplacementFunc = ...
			return function( {FunctionArguments} )
				return ReplacementFunc( OldFunc{Arguments} )
			end]],
			NumArguments,
			"@lua/shine/core/shared/hook.lua/CustomClassHook",
			OldFunc,
			ReplacementFuncTemplate
		)
	else
		ReplacementFunc = CodeGen.GenerateFunctionWithArguments(
			ReplacementFuncTemplate, NumArguments, "@lua/shine/core/shared/hook.lua/ClassHook",
			HookName, Caller, OldFunc
		)
	end

	return ReplaceMethod( Class, Method, ReplacementFunc )
end

--[[
	Replaces the given global function with ReplacementFunc.

	Inputs: Global function name, replacement function.
	Output: Original function.
]]
local function AddGlobalHook( ReplacementFunc, HookName, Caller, FuncName )
	local Path = StringExplode( FuncName, ".", true )

	local Func = _G
	local NumSegments = #Path
	local Prev

	for i = 1, NumSegments do
		Prev = Func
		Func = Func[ Path[ i ] ]

		-- Doesn't exist!
		if not Func then
			Print( "[Shine] [Warn] Attempted to hook global value %s which does not exist!", FuncName )
			return nil
		end
	end

	if not Shine.IsCallable( Func ) then
		-- Ideally this should throw an error, but there may be cases where old code hooks a non-callable global
		-- value and throwing here would break it.
		Print(
			"[Shine] [Warn] Hooking global value %s which is not callable (type: %s)!", FuncName, type( Func )
		)
	end

	local NumArguments = GetNumArguments( Func )
	if not IsType( ReplacementFunc, "string" ) then
		-- Maintain backwards compatibility with custom hook handlers while still helping to remove var-args.
		Prev[ Path[ NumSegments ] ] = CodeGen.GenerateFunctionWithArguments(
			[[local OldFunc, ReplacementFunc = ...
			return function( {FunctionArguments} )
				return ReplacementFunc( OldFunc{Arguments} )
			end]],
			NumArguments,
			"@lua/shine/core/shared/hook.lua/CustomGlobalHook",
			Func,
			ReplacementFunc
		)
	else
		Prev[ Path[ NumSegments ] ] = CodeGen.GenerateFunctionWithArguments(
			ReplacementFunc, NumArguments, "@lua/shine/core/shared/hook.lua/GlobalHook",
			HookName, Caller, Func
		)
	end

	return Func
end

--[[
	All available preset hooking methods:

	- Replace: Replaces the function with a Shine hook call.

	- PassivePre: Calls the given Shine hook, then runs the
	original function and returns its value(s).

	- PassivePost: Runs and stores the return values of the original function,
	then calls the Shine hook, then returns the original return values.

	- ActivePre: Calls the given Shine hook and returns its values if it returned any.
	Otherwise it returns the original function's values.

	- ActivePost: Runs and stores the return values of the original function,
	then calls the Shine hook. If the Shine hook returned values, they are returned.
	Otherwise, the original values are returned.

	- Halt: Calls the given Shine hook. If it returns a non-nil value,
	the method is stopped and returns nothing. Otherwise the original method is returned.
]]
local HookModes = {
	Replace = function( Adder, HookName, ... )
		return Adder( [[local HookName, Call = ...
			return function( {FunctionArguments} )
				return Call( HookName{Arguments} )
			end]], HookName, Call, ... )
	end,
	PassivePre = function( Adder, HookName, ... )
		return Adder( [[local HookName, Broadcast, OldFunc = ...
			return function( {FunctionArguments} )
				Broadcast( HookName{Arguments} )

				return OldFunc( {FunctionArguments} )
			end]], HookName, Broadcast, ... )
	end,
	PassivePost = function( Adder, HookName, ... )
		return Adder( [[local HookName, Broadcast, OldFunc = ...
			return function( {FunctionArguments} )
				local a, b, c, d, e, f = OldFunc( {FunctionArguments} )

				Broadcast( HookName{Arguments} )

				return a, b, c, d, e, f
			end]], HookName, Broadcast, ... )
	end,

	ActivePre = function( Adder, HookName, ... )
		return Adder( [[local HookName, Call, OldFunc = ...
			return function( {FunctionArguments} )
				local a, b, c, d, e, f = Call( HookName{Arguments} )

				if a ~= nil then
					return a, b, c, d, e, f
				end

				return OldFunc( {FunctionArguments} )
			end]], HookName, Call, ... )
	end,

	ActivePost = function( Adder, HookName, ... )
		return Adder( [[local HookName, Call, OldFunc = ...
			return function( {FunctionArguments} )
				local a, b, c, d, e, f = OldFunc( {FunctionArguments} )
				local g, h, i, j, k, l = Call( HookName{Arguments} )

				if g ~= nil then
					return g, h, i, j, k, l
				end

				return a, b, c, d, e, f
			end]], HookName, Call, ... )
	end,

	Halt = function( Adder, HookName, ... )
		return Adder( [[local HookName, Call, OldFunc = ...
			return function( {FunctionArguments} )
				local Ret = Call( HookName{Arguments} )
				if Ret ~= nil then return end

				return OldFunc( {FunctionArguments} )
			end]], HookName, Call, ... )
	end
}

-- Track which hooks have been setup, and what they're targeting.
-- This allows for skipping duplicate setup calls, and also detecting cases where the same
-- hook name is used in different places/modes.
local SetupHooks = {}

local function CheckExistingHook( HookName, Target, Mode, Options )
	local ExistingHook = SetupHooks[ HookName ]
	if ExistingHook then
		if ExistingHook.Target == Target and ExistingHook.Mode == Mode then
			-- No need to hook again if targeting the same function with the same mode.
			return true, ExistingHook
		end

		if not IsType( Options, "table" ) or not Options.OverrideWithoutWarning then
			Print(
				"[Shine] [Warn] Hook '%s' will be called for both %s (%s) and %s (%s).",
				HookName, Target, Mode, ExistingHook.Target, ExistingHook.Mode
			)
		end

		ExistingHook.Target = Target
		ExistingHook.Mode = Mode
		ExistingHook.OldFunc = nil
	else
		ExistingHook = {
			Target = Target,
			Mode = Mode
		}
		SetupHooks[ HookName ] = ExistingHook
	end

	return false, ExistingHook
end

--[[
	Sets up a Shine hook for a class method.

	Inputs:
		1. Class name.
		2. Method name.
		3. Shine hook name to call when this method is run.
		4. Mode to hook with.

	Output: Original function we have now replaced.

	Mode can either be a string from the HookModes table above,
	or it can be a custom hook function.

	The function will be passed the original function, then the arguments it was run with.
]]
local function SetupClassHook( Class, Method, HookName, Mode, Options )
	local Target = StringFormat( "%s:%s", Class, Method )
	local HookedAlready, ExistingHook = CheckExistingHook( HookName, Target, Mode, Options )
	if HookedAlready then
		return ExistingHook.OldFunc
	end

	local OldFunc
	if IsType( Mode, "function" ) then
		OldFunc = AddClassHook( Mode, HookName, nil, Class, Method )
	else
		local HookFunc = HookModes[ Mode ]
		if not HookFunc then
			error( StringFormat( "Unknown hook mode: %s", Mode ), 2 )
		end

		OldFunc = HookFunc( AddClassHook, HookName, Class, Method )
	end

	ExistingHook.OldFunc = OldFunc

	return OldFunc
end
Hook.SetupClassHook = SetupClassHook

--[[
	Sets up a Shine hook for a global function.

	Inputs:
		1. Global function name.
		2. Mode to hook with.

	Output: Original function we have now replaced.

	Mode can either be a string from the HookModes table above,
	or it can be a custom hook function.

	The function will be passed the original function, then the arguments it was run with.
]]
local function SetupGlobalHook( FuncName, HookName, Mode, Options )
	local Target = StringFormat( "_G.%s", FuncName )
	local HookedAlready, ExistingHook = CheckExistingHook( HookName, Target, Mode, Options )
	if HookedAlready then
		return ExistingHook.OldFunc
	end

	local OldFunc
	if IsType( Mode, "function" ) then
		OldFunc = AddGlobalHook( Mode, HookName, nil, FuncName )
	else
		local HookFunc = HookModes[ Mode ]
		if not HookFunc then
			error( StringFormat( "Unknown hook mode: %s", Mode ), 2 )
		end

		OldFunc = HookFunc( AddGlobalHook, HookName, FuncName )
	end

	ExistingHook.OldFunc = OldFunc

	return OldFunc
end
Hook.SetupGlobalHook = SetupGlobalHook

--[[
	Replaces a function upvalue in the upvalues of TargetFunc.
	Your replacement receives a copy of every upvalue from the original function.

	Inputs:
		1. Function to grab the upvalue from.
		2. Name of the upvalue function you want to replace.
		3. The replacement function you want to use.
		4. Any upvalues you want to change for your replacement version.
		5. Should said upvalues be replaced recursively?

	Output:
		The original function that has now been replaced.
]]
function Hook.ReplaceLocalFunction( TargetFunc, UpvalueName, Replacement, DifferingValues, Recursive )
	local Value, i, Func = Shine.GetUpValue( TargetFunc, UpvalueName )

	if not Value or not IsType( Value, "function" ) then return end

	--Copy all the upvalues from the original function to our replacement.
	Shine.MimicFunction( Value, Replacement, DifferingValues, Recursive )

	--Now replace the local function in the original location with our replacement version.
	DebugSetUpValue( Func or TargetFunc, i, Replacement )

	return Value
end

do
	--[[
		Event hooks.
	]]
	local function Think( DeltaTime )
		Broadcast( "Think", DeltaTime )
	end
	Event.Hook( Server and "UpdateServer" or "UpdateClient", Think )
end

do
	local OldScriptLoad = Script.Load
	local SeenScripts = {}

	local AllLoadedScripts = {}
	if IsType( Script.includes, "table" ) then
		-- Seemingly undocumented table tracking all loaded script files.
		setmetatable( AllLoadedScripts, { __index = Script.includes } )
	else
		AllLoadedScripts = SeenScripts
	end

	--[[
		Ensures the given callback is executed, either immediately if its pre-requisite file
		is known to have loaded, or otherwise after the file loads.
	]]
	function Hook.CallAfterFileLoad( FileName, Callback, Priority )
		if AllLoadedScripts[ FileName ] then
			Callback()
		end

		-- Always add the hook in case the file is reloaded.
		Add( "PostLoadScript:"..FileName, Callback, Callback, Priority )
	end

	-- Override Script.Load to allow finer entry point control.
	local function ScriptLoad( Script, Reload )
		if not SeenScripts[ Script ] or Reload then
			-- Call only once per script to avoid extra overhead.
			SeenScripts[ Script ] = true

			Broadcast( "PreLoadScript", Script, Reload )
			Broadcast( "PreLoadScript:"..Script, Reload )

			local Ret = OldScriptLoad( Script, Reload )

			Broadcast( "PostLoadScript", Script, Reload )
			Broadcast( "PostLoadScript:"..Script, Reload )

			return Ret
		end

		return OldScriptLoad( Script, Reload )
	end
	Script.Load = ScriptLoad

	local function MapPreLoad()
		BroadcastOnce "MapPreLoad"
	end
	Event.Hook( "MapPreLoad", MapPreLoad )

	local function MapPostLoad()
		BroadcastOnce "MapPostLoad"
	end
	Event.Hook( "MapPostLoad", MapPostLoad )
end

do
	local Environment = Server or Client
	local OriginalHookNWMessage = Environment.HookNetworkMessage

	function Environment.HookNetworkMessage( Name, Callback )
		local OverrideCallback = Call( "HookNetworkMessage:"..Name, Name, Callback )
		if IsType( OverrideCallback, "function" ) then
			Callback = OverrideCallback
		end

		return OriginalHookNWMessage( Name, Callback )
	end

	local OriginalRegisterNetworkMessage = Shared.RegisterNetworkMessage
	function Shared.RegisterNetworkMessage( Name, MessageDefinition )
		local OverrideDefinition = Call( "RegisterNetworkMessage:"..Name, Name, MessageDefinition )
		if IsType( OverrideDefinition, "table" ) then
			MessageDefinition = OverrideDefinition
		end

		-- The engine's argument checking thinks a nil value is an error, rather than treating it
		-- as the case where it's given only one argument...
		if MessageDefinition then
			return OriginalRegisterNetworkMessage( Name, MessageDefinition )
		end

		return OriginalRegisterNetworkMessage( Name )
	end
end

-- Note that it's important to override the initial registration, rather than re-register the message, as the
-- network message hook callback only receives data for the values present at the time it was registered.
Add( "RegisterNetworkMessage:Chat", "AddSteamIDToMessage", function( Name, Definition )
	Definition.steamId = "integer"
	Definition.clientId = "integer"
end )

-- Client specific hooks.
if Client then
	local function LoadComplete()
		BroadcastOnce "OnMapLoad"
	end
	Event.Hook( "LoadComplete", LoadComplete )

	local function OnClientDisconnected( Reason )
		Broadcast( "ClientDisconnected", Reason )
	end
	Event.Hook( "ClientDisconnected", OnClientDisconnected )

	Add( "HookNetworkMessage:Chat", "SetupOnChatMessageReceived", function( Name, Callback )
		return function( Data )
			local Handled = Call( "OnChatMessageReceived", {
				LocationID = Data.locationId,
				Message = Data.message,
				Name = Data.playerName,
				ClientID = Data.clientId,
				SteamID = Data.steamId,
				TeamNumber = Data.teamNumber,
				TeamOnly = Data.teamOnly,
				TeamType = Data.teamType
			} )
			if Handled then return end

			return Callback( Data )
		end
	end, MAX_PRIORITY )

	-- Need to hook the GUI manager, hooking the events directly blocks all input for some reason...
	Add( "OnMapLoad", "HookGUIEvents", function()
		local GUIManager = GetGUIManager()
		local OldSendKeyEvent = GUIManager.SendKeyEvent

		function GUIManager:SendKeyEvent( Key, Down, Amount )
			local Result = Call( "PlayerKeyPress", Key, Down, Amount )

			if Result then return true end

			return OldSendKeyEvent( self, Key, Down, Amount )
		end

		local OldSendCharacterEvent = GUIManager.SendCharacterEvent

		function GUIManager:SendCharacterEvent( Char )
			local Result = Call( "PlayerType", Char )

			if Result then return true end

			return OldSendCharacterEvent( self, Char )
		end

		local OldResChange = GUIManager.OnResolutionChanged

		function GUIManager:OnResolutionChanged( OldX, OldY, NewX, NewY )
			Broadcast( "PreOnResolutionChanged", OldX, OldY, NewX, NewY )

			OldResChange( self, OldX, OldY, NewX, NewY )

			Broadcast( "OnResolutionChanged", OldX, OldY, NewX, NewY )
		end

		SetupGlobalHook( "ChatUI_EnterChatMessage", "StartChat", "ActivePre" )
		SetupGlobalHook( "CommanderUI_Logout", "OnCommanderUILogout", "PassivePost" )

		SetupClassHook( "Commander", "OnDestroy", "OnCommanderLogout", function( OldFunc, Commander )
			-- Do nothing if the commander isn't the local player.
			if not Commander.hudSetup then return OldFunc( Commander ) end

			OldFunc( Commander )

			-- Call after the mouse has been disabled for the commander to allow SGUI elements
			-- to properly close themselves and avoid getting stuck on screen.
			Broadcast( "OnCommanderLogout", Commander )
		end )
		SetupClassHook( "Commander", "OnInitLocalClient", "OnCommanderLogin", "PassivePre" )

		SetupClassHook( "HelpScreen", "Display", "OnHelpScreenDisplay", "PassivePost" )
		SetupClassHook( "HelpScreen", "Hide", "OnHelpScreenHide", "PassivePost" )

		Shine.Hook.SetupGlobalHook( "ClientUI.EvaluateUIVisibility",
			"EvaluateUIVisibility", "PassivePost" )

		local OptionsFunctions = {
			"Client.SetOptionInteger",
			"Client.SetOptionFloat",
			"Client.SetOptionString",
			"Client.SetOptionBoolean"
		}
		for i = 1, #OptionsFunctions do
			Shine.Hook.SetupGlobalHook( OptionsFunctions[ i ], "OnClientOptionChanged", "PassivePost", {
				OverrideWithoutWarning = true
			} )
		end

		Add( "OnClientOptionChanged", function( Name, Value )
			return Broadcast( "OnClientOptionChanged:"..Name, Value )
		end, MAX_PRIORITY )
	end, MAX_PRIORITY )

	Event.Hook( "LocalPlayerChanged", function()
		local Player = Client.GetLocalPlayer()
		if Player then
			Broadcast( "OnLocalPlayerChanged", Player )
		end
	end )

	Add( "Think", "ClientOnFirstThink", function()
		BroadcastOnce( "OnFirstThink" )
		Remove( "Think", "ClientOnFirstThink" )
	end )

	return
end

-- Need to ensure connection events fire after Gamerules sees them, otherwise no player is assigned to the client.
local function HookConnectionEvents()
	local function ClientConnect( Client )
		Broadcast( "ClientConnect", Client )
	end
	Event.Hook( "ClientConnect", ClientConnect )

	local function ClientDisconnect( Client )
		Broadcast( "ClientDisconnect", Client )
	end
	Event.Hook( "ClientDisconnect", ClientDisconnect )
end
Add( "MapPostLoad", HookConnectionEvents, HookConnectionEvents, MAX_PRIORITY )

do
	local function MapLoadEntity( MapName, GroupName, Values )
		Broadcast( "MapLoadEntity", MapName, GroupName, Values )
	end
	Event.Hook( "MapLoadEntity", MapLoadEntity )
end

do
	local OldEventHook = Event.Hook
	local OldReservedSlot

	local function CheckConnectionAllowed( ID )
		local Result, Reason = Call( "CheckConnectionAllowed", ID )

		if Result ~= nil then return Result, Reason end

		return OldReservedSlot( ID )
	end

	--[[
		Detour the event hook function so we can override the result of
		CheckConnectionAllowed. Otherwise it would return the default function's value
		and never call our hook.
	]]
	function Event.Hook( Name, Func )
		local Override, NewFunc = Call( "NS2EventHook", Name, Func )

		if Override then
			return OldEventHook( Name, NewFunc )
		end

		if Name ~= "CheckConnectionAllowed" then
			return OldEventHook( Name, Func )
		end

		OldReservedSlot = Func

		Func = CheckConnectionAllowed

		return OldEventHook( Name, Func )
	end
end

Add( "HookNetworkMessage:ChatClient", "AddChatCallback", function( MessageName, Callback )
	return function( Client, Message )
		local Result = Call( "PlayerSay", Client, Message )
		if Result then
			if Result == "" then return end
			Message.message = Result
		end

		return Callback( Client, Message )
	end
end, Hook.MAX_PRIORITY )

--[[
	Hook to run after everything has loaded.
	Here we replace class methods in order to hook into certain important events.
]]
Add( "Think", "ReplaceMethods", function()
	Remove( "Think", "ReplaceMethods" )

	SetupGlobalHook( "GetHasReservedSlotAccess", "HasReservedSlotAccess", "ActivePre" )

	local Gamerules = "NS2Gamerules"

	SetupClassHook( "Player", "OnProcessMove", "OnProcessMove", "PassivePre" )
	SetupClassHook( "Player", "SetName", "PlayerNameChange", function( OldFunc, self, Name )
		local OldName = self:GetName()
		local NewName = Call( "CheckPlayerName", self, Name, OldName ) or Name

		OldFunc( self, NewName )

		Broadcast( "PlayerNameChange", self, NewName, OldName )
	end )

	SetupClassHook( "Spectator", "OnProcessMove", "OnProcessMove", "PassivePre", { OverrideWithoutWarning = true } )

	SetupClassHook( Gamerules, "EndGame", "EndGame", "PassivePre" )
	SetupClassHook( Gamerules, "OnEntityKilled", "OnEntityKilled", "PassivePre" )

	SetupClassHook( "CommandStructure", "LoginPlayer", "CommLoginPlayer", "PassivePre" )
	SetupClassHook( "CommandStructure", "OnCommanderLogin", "OnCommanderLogin", "PassivePre" )
	SetupClassHook( "CommandStructure", "Logout", "CommLogout", "PassivePre" )
	SetupClassHook( Gamerules, "OnCommanderLogin", "ValidateCommanderLogin", "ActivePre" )

	-- Need to double check for kTechId and the appropriate enums in case a different gamemode is running that doesn't
	-- use the NS2 code that creates this enum.
	if kTechId then
		local function CallIfResearchIDMatches( HookName, TechID )
			return function( OldFunc, Building, ResearchID, ... )
				if ResearchID == TechID then
					Broadcast( HookName, Building, ResearchID, ... )
				end
				return OldFunc( Building, ResearchID, ... )
			end
		end

		if rawget( kTechId, "Recycle" ) then
			SetupClassHook(
				"RecycleMixin", "OnResearch", "OnRecycle",
				CallIfResearchIDMatches( "OnRecycle", kTechId.Recycle )
			)
			SetupClassHook(
				"RecycleMixin", "OnResearchComplete", "OnBuildingRecycled",
				CallIfResearchIDMatches( "OnBuildingRecycled", kTechId.Recycle )
			)
			SetupClassHook(
				"RecycleMixin", "OnResearchCancel", "OnRecycleCancelled",
				CallIfResearchIDMatches( "OnRecycleCancelled", kTechId.Recycle )
			)
		end

		if rawget( kTechId, "Consume" ) then
			SetupClassHook(
				"ConsumeMixin", "OnResearch", "OnConsume",
				CallIfResearchIDMatches( "OnConsume", kTechId.Consume )
			)
			SetupClassHook(
				"ConsumeMixin", "OnResearchComplete", "OnBuildingConsumed",
				CallIfResearchIDMatches( "OnBuildingConsumed", kTechId.Consume )
			)
			SetupClassHook(
				"ConsumeMixin", "OnResearchCancel", "OnConsumeCancelled",
				CallIfResearchIDMatches( "OnConsumeCancelled", kTechId.Consume )
			)
		end
	end

	SetupClassHook( "Commander", "ProcessTechTreeActionForEntity", "OnCommanderTechTreeAction",
		"PassivePre" )
	SetupClassHook( "Commander", "TriggerNotification", "OnCommanderNotify", "PassivePre" )
	SetupClassHook( "Commander", "Eject", "OnCommanderEjected", "PassivePre" )

	SetupClassHook( "PlayingTeam", "VoteToEjectCommander", "OnVoteToEjectCommander", "PassivePost" )
	SetupClassHook( "PlayingTeam", "VoteToGiveUp", "OnVoteToConcede", "PassivePost" )

	SetupClassHook( "ConstructMixin", "OnInitialized", "OnConstructInit", "PassivePre" )

	SetupClassHook( Gamerules, "UpdatePregame", "UpdatePregame", "Halt" )
	SetupClassHook( Gamerules, "UpdateWarmUp", "UpdateWarmUp", "Halt" )
	SetupClassHook( Gamerules, "CheckGameStart", "CheckGameStart", "Halt" )
	SetupClassHook( Gamerules, "CastVoteByPlayer", "CastVoteByPlayer", "Halt" )
	SetupClassHook( Gamerules, "SetGameState", "SetGameState", function( OldFunc, self, State )
		local CurState = self.gameState

		OldFunc( self, State )

		Broadcast( "SetGameState", self, State, CurState )
	end )
	SetupClassHook( Gamerules, "ResetGame", "ResetGame", "PassivePost" )
	SetupClassHook( Gamerules, "GetCanPlayerHearPlayer", "CanPlayerHearPlayer", "ActivePre" )
	SetupClassHook( Gamerules, "JoinTeam", "JoinTeam", function( OldFunc, self, Player, NewTeam, Force, ShineForce )
		local Override, OverrideTeam = Call( "JoinTeam", self, Player, NewTeam, Force, ShineForce )

		if Override ~= nil then
			if Override then
				NewTeam = OverrideTeam
			else
				return false, Player
			end
		end

		local OldTeam = Player:GetTeamNumber()

		local Bool, NewPlayer = OldFunc( self, Player, NewTeam, Force )

		if Bool then
			Broadcast( "PostJoinTeam", self, NewPlayer, OldTeam, NewTeam, Force, ShineForce )
		end

		return Bool, NewPlayer or Player
	end )

	local OldCycleMap = MapCycle_CycleMap
	local OldChangeMap = MapCycle_ChangeMap

	if not OldCycleMap then
		Script.Load "lua/MapCycle.lua"
		OldCycleMap = MapCycle_CycleMap
		OldChangeMap = MapCycle_ChangeMap
	end

	function MapCycle_ChangeMap( MapName )
		Broadcast( "MapChange" )

		return OldChangeMap( MapName )
	end

	function MapCycle_CycleMap( CurrentMap )
		local Result = Call( "OnCycleMap" )

		if Result ~= nil then return end

		Broadcast( "MapChange" )

		return OldCycleMap( CurrentMap )
	end

	local OldTestCycle = MapCycle_TestCycleMap

	function MapCycle_TestCycleMap()
		local Result = Call( "ShouldCycleMap" )

		if Result ~= nil then return Result end

		return OldTestCycle()
	end

	local OldStartVote = StartVote
	if OldStartVote then
		StartVote = function( VoteName, Client, Data )
			local Allowed, Reason = Call( "NS2StartVote", VoteName, Client, Data )
			if Allowed == false then
				if Reason == nil or IsType( Reason, "number" ) then
					Shine.SendNetworkMessage( Client, "VoteCannotStart", {
						reason = Reason or kVoteCannotStartReason.DisabledByAdmin
					}, true )
				end

				return
			end

			-- StartVote doesn't return anything to indicate it started, so this check is required...
			if GetStartVoteAllowed( VoteName, Client, Data ) == kVoteCannotStartReason.VoteAllowedToStart then
				Broadcast( "OnNS2VoteStarting", VoteName, Client, Data )
			end

			return OldStartVote( VoteName, Client, Data )
		end
	end

	BroadcastOnce( "OnFirstThink" )
end )
