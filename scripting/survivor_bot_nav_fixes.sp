#include <sourcemod>

#define REQUIRE_EXTENSIONS
#include <dhooks>

#define GAMEDATA_FILE	"survivor_bot_nav_fixes"

enum NavAttributeType
{
	NAV_MESH_INVALID		= 0,
	NAV_MESH_CROUCH			= 0x0000001,				// must crouch to use this node/area
	NAV_MESH_JUMP			= 0x0000002,				// must jump to traverse this area (only used during generation)
	NAV_MESH_PRECISE		= 0x0000004,				// do not adjust for obstacles, just move along area
	NAV_MESH_NO_JUMP		= 0x0000008,				// inhibit discontinuity jumping
	NAV_MESH_STOP			= 0x0000010,				// must stop when entering this area
	NAV_MESH_RUN			= 0x0000020,				// must run to traverse this area
	NAV_MESH_WALK			= 0x0000040,				// must walk to traverse this area
	NAV_MESH_AVOID			= 0x0000080,				// avoid this area unless alternatives are too dangerous
	NAV_MESH_TRANSIENT		= 0x0000100,				// area may become blocked, and should be periodically checked
	NAV_MESH_DONT_HIDE		= 0x0000200,				// area should not be considered for hiding spot generation
	NAV_MESH_STAND			= 0x0000400,				// bots hiding in this area should stand
	NAV_MESH_NO_HOSTAGES	= 0x0000800,				// hostages shouldn't use this area
	NAV_MESH_STAIRS			= 0x0001000,				// this area represents stairs, do not attempt to climb or jump them - just walk up
	NAV_MESH_NO_MERGE		= 0x0002000,				// don't merge this area with adjacent areas
	NAV_MESH_OBSTACLE_TOP	= 0x0004000,				// this nav area is the climb point on the tip of an obstacle
	NAV_MESH_CLIFF			= 0x0008000,				// this nav area is adjacent to a drop of at least CliffHeight

	NAV_MESH_FIRST_CUSTOM	= 0x00010000,				// apps may define custom app-specific bits starting with this value
	NAV_MESH_LAST_CUSTOM	= 0x04000000,				// apps must not define custom app-specific bits higher than with this value

	NAV_MESH_BLOCKED_PROPDOOR	= 0x10000000,				// area is blocked by prop_door_rotating

	NAV_MESH_HAS_ELEVATOR	= 0x40000000,				// area is in an elevator's path
	NAV_MESH_NAV_BLOCKER	= 0x80000000				// area is blocked by nav blocker ( Alas, needed to hijack a bit in the attributes to get within a cache line [7/24/2008 tom])
};

DynamicHook g_hDHook_ILocomotion_IsRunning = null;
DynamicHook g_hDHook_CBasePlayer_OnNavAreaChanged = null;

Handle g_hSDKCall_INextBot_GetLocomotionInterface = null;
Handle g_hSDKCall_INextBot_MySurvivorBotPointer = null;
Handle g_hSDKCall_NextBotPlayer_CTerrorPlayer_MyNextBotPointer = null;
Handle g_hSDKCall_CBaseCombatCharacter_GetLastKnownArea = null;
Handle g_hSDKCall_ILocomotion_Jump = null;

int g_nOffset_PlayerLocomotion_m_player = -1;
int g_nOffset_CNavArea_m_attributeFlags = -1;
int g_nOffset_NextBotPlayer_CTerrorPlayer_m_inputButtons = -1;
int g_nOffset_NextBotPlayer_CTerrorPlayer_m_crouchButtonTimer = -1;

bool g_bStopping[32+1];

Address INextBot_GetLocomotionInterface( const Address adrThis )
{
	return SDKCall( g_hSDKCall_INextBot_GetLocomotionInterface, adrThis );
}

int INextBot_MySurvivorBotPointer( const Address adrThis )
{
	return SDKCall( g_hSDKCall_INextBot_MySurvivorBotPointer, adrThis );
}

Address NextBotPlayer_CTerrorPlayer_MyNextBotPointer( const int iClient )
{
	return SDKCall( g_hSDKCall_NextBotPlayer_CTerrorPlayer_MyNextBotPointer, iClient );
}

Address CBaseCombatCharacter_GetLastKnownArea( const Address adrClient )
{
	return SDKCall( g_hSDKCall_CBaseCombatCharacter_GetLastKnownArea, adrClient );
}

void ILocomotion_Jump( const Address adrThis )
{
	SDKCall( g_hSDKCall_ILocomotion_Jump, adrThis );
}

NavAttributeType CNavArea_GetAttributes( const Address adrNavArea )
{
	return view_as< NavAttributeType >( LoadFromAddress( adrNavArea + view_as< Address >( g_nOffset_CNavArea_m_attributeFlags ), NumberType_Int32 ) );
}

void INextBotPlayerInput_PressCrouchButton( int iClient, float flDuration = -1.0 )
{
	int fInputButtons = GetEntData( iClient, g_nOffset_NextBotPlayer_CTerrorPlayer_m_inputButtons );

	SetEntData( iClient, g_nOffset_NextBotPlayer_CTerrorPlayer_m_inputButtons, fInputButtons | IN_DUCK );

	SetEntDataFloat( iClient, g_nOffset_NextBotPlayer_CTerrorPlayer_m_crouchButtonTimer + 4, flDuration );
	SetEntDataFloat( iClient, g_nOffset_NextBotPlayer_CTerrorPlayer_m_crouchButtonTimer + 8, GetGameTime() + flDuration );
}

public MRESReturn DHook_PlayerLocomotion_IsRunning( Address adrThis, DHookReturn hReturn, DHookParam hParams )
{
	Address adrClient = view_as< Address >( LoadFromAddress( adrThis + view_as< Address >( g_nOffset_PlayerLocomotion_m_player ), NumberType_Int32 ) );
	Address adrLastKnownArea = CBaseCombatCharacter_GetLastKnownArea( adrClient );

	if ( adrLastKnownArea && CNavArea_GetAttributes( adrLastKnownArea ) & NAV_MESH_WALK )
	{
		DHookSetReturn( hReturn, false );

		return MRES_Supercede;
	}

	return MRES_Ignored;
}

public MRESReturn DHook_SurvivorBot_OnNavAreaChanged_Post( int iThis, DHookParam hParams )
{
	Address adrEnteredArea = hParams.GetAddress( 1 );

	if ( adrEnteredArea == Address_Null )
	{
		return MRES_Ignored;
	}

	// if we just entered a 'stop' area, set the flag
	if ( CNavArea_GetAttributes( adrEnteredArea ) & NAV_MESH_STOP )
	{
		g_bStopping[iThis] = true;
	}

	return MRES_Ignored;
}

public void OnClientPutInServer( int iClient )
{
	char szNetClass[32];
	GetEntityNetClass( iClient, szNetClass, sizeof( szNetClass ) );

	if ( StrEqual( szNetClass, "SurvivorBot", true ) )
	{
		Address adrNextBot = NextBotPlayer_CTerrorPlayer_MyNextBotPointer( iClient );

		g_hDHook_ILocomotion_IsRunning.HookRaw( Hook_Pre, INextBot_GetLocomotionInterface( adrNextBot ), DHook_PlayerLocomotion_IsRunning );
		g_hDHook_CBasePlayer_OnNavAreaChanged.HookEntity( Hook_Post, iClient, DHook_SurvivorBot_OnNavAreaChanged_Post );
	}
}

public MRESReturn DDetour_PathFollower_Climbing( Address adrThis, DHookReturn hReturn, DHookParam hParams )
{
	Address adrNextBot = hParams.GetAddress( 1 );

	int iSurvivorBot = INextBot_MySurvivorBotPointer( adrNextBot );

	if ( iSurvivorBot != INVALID_ENT_REFERENCE )
	{
		Address adrLastKnownArea = CBaseCombatCharacter_GetLastKnownArea( GetEntityAddress( iSurvivorBot ) );

		if ( adrLastKnownArea && CNavArea_GetAttributes( adrLastKnownArea ) & NAV_MESH_NO_JUMP )
		{
			DHookSetReturn( hReturn, false );

			return MRES_Supercede;
		}
	}

	return MRES_Ignored;
}

public MRESReturn DDetour_PathFollower_Update( Address adrThis, DHookParam hParams )
{
	Address adrNextBot = hParams.GetAddress( 1 );

	int iSurvivorBot = INextBot_MySurvivorBotPointer( adrNextBot );

	if ( iSurvivorBot != INVALID_ENT_REFERENCE )
	{
		Address adrLastKnownArea = CBaseCombatCharacter_GetLastKnownArea( GetEntityAddress( iSurvivorBot ) );

		if ( adrLastKnownArea )
		{
			NavAttributeType fNavAttributeType = CNavArea_GetAttributes( adrLastKnownArea );

			if ( fNavAttributeType & NAV_MESH_CROUCH )
			{
				INextBotPlayerInput_PressCrouchButton( iSurvivorBot );
			}

			if ( g_bStopping[iSurvivorBot] )
			{
				float flVecAbsVelocity[3];
				GetEntPropVector( iSurvivorBot, Prop_Data, "m_vecAbsVelocity", flVecAbsVelocity );

				if ( GetVectorLength( flVecAbsVelocity, true ) >= 0.1 )
				{
					return MRES_Supercede;
				}

				g_bStopping[iSurvivorBot] = false;
			}

			if ( fNavAttributeType & NAV_MESH_JUMP )
			{
				ILocomotion_Jump( INextBot_GetLocomotionInterface( adrNextBot ) );
			}
		}
	}

	return MRES_Ignored;
}

public void OnPluginStart()
{
	GameData hGameData = new GameData( GAMEDATA_FILE );

	if ( !hGameData )
	{
		SetFailState( "Unable to load gamedata file \"" ... GAMEDATA_FILE ... "\"" );
	}

#define GET_OFFSET_WRAPPER(%0,%1)\
	%0 = hGameData.GetOffset( %1 );\
	\
	if ( %0 == -1 )\
	{\
		delete hGameData;\
		\
		SetFailState( "Unable to find gamedata offset entry for \"" ... %1 ... "\"" );\
	}

#define PREP_SDK_VCALL_SET_FROM_CONF_WRAPPER(%0)\
	if ( !PrepSDKCall_SetFromConf( hGameData, SDKConf_Virtual, %0 ) ) \
	{\
		delete hGameData;\
		\
		SetFailState( "Unable to find gamedata offset entry for \"" ... %0 ... "\"" );\
	}

#define DYNAMIC_DETOUR_SET_FROM_CONF_WRAPPER(%0,%1)\
	if ( !%0.SetFromConf( hGameData, SDKConf_Signature, %1 ) )\
	{\
		delete hGameData;\
		\
		SetFailState( "Unable to find gamedata signature entry for \"" ... %1 ... "\"" );\
	}

	int iVtbl_ILocomotion_IsRunning;
	GET_OFFSET_WRAPPER(iVtbl_ILocomotion_IsRunning, "ILocomotion::IsRunning")

	int iVtbl_CBasePlayer_OnNavAreaChanged;
	GET_OFFSET_WRAPPER(iVtbl_CBasePlayer_OnNavAreaChanged, "CBasePlayer::OnNavAreaChanged")

	GET_OFFSET_WRAPPER(g_nOffset_PlayerLocomotion_m_player, "PlayerLocomotion::m_player")
	GET_OFFSET_WRAPPER(g_nOffset_CNavArea_m_attributeFlags, "CNavArea::m_attributeFlags")
	GET_OFFSET_WRAPPER(g_nOffset_NextBotPlayer_CTerrorPlayer_m_inputButtons, "NextBotPlayer<CTerrorPlayer>::m_inputButtons")
	GET_OFFSET_WRAPPER(g_nOffset_NextBotPlayer_CTerrorPlayer_m_crouchButtonTimer, "NextBotPlayer<CTerrorPlayer>::m_crouchButtonTimer")

	g_hDHook_ILocomotion_IsRunning = new DynamicHook( iVtbl_ILocomotion_IsRunning, HookType_Raw, ReturnType_Bool, ThisPointer_Address );
	g_hDHook_CBasePlayer_OnNavAreaChanged = new DynamicHook( iVtbl_CBasePlayer_OnNavAreaChanged, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity );
	g_hDHook_CBasePlayer_OnNavAreaChanged.AddParam( HookParamType_ObjectPtr );
	g_hDHook_CBasePlayer_OnNavAreaChanged.AddParam( HookParamType_ObjectPtr );

	DynamicDetour hDDetour_PathFollower_Climbing = new DynamicDetour( Address_Null, CallConv_THISCALL, ReturnType_Bool, ThisPointer_Address );
	DynamicDetour hDDetour_PathFollower_Update = new DynamicDetour( Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Address );

	DYNAMIC_DETOUR_SET_FROM_CONF_WRAPPER(hDDetour_PathFollower_Climbing, "PathFollower::Climbing")
	DYNAMIC_DETOUR_SET_FROM_CONF_WRAPPER(hDDetour_PathFollower_Update, "PathFollower::Update")

	hDDetour_PathFollower_Climbing.AddParam( HookParamType_ObjectPtr );
	hDDetour_PathFollower_Climbing.AddParam( HookParamType_ObjectPtr );
	hDDetour_PathFollower_Climbing.AddParam( HookParamType_VectorPtr );
	hDDetour_PathFollower_Climbing.AddParam( HookParamType_VectorPtr );
	hDDetour_PathFollower_Climbing.AddParam( HookParamType_Float );
	hDDetour_PathFollower_Climbing.Enable( Hook_Pre, DDetour_PathFollower_Climbing );

	hDDetour_PathFollower_Update.AddParam( HookParamType_ObjectPtr );
	hDDetour_PathFollower_Update.Enable( Hook_Pre, DDetour_PathFollower_Update );

	StartPrepSDKCall( SDKCall_Raw );
	PREP_SDK_VCALL_SET_FROM_CONF_WRAPPER("INextBot::GetLocomotionInterface")
	PrepSDKCall_SetReturnInfo( SDKType_PlainOldData, SDKPass_Plain );
	g_hSDKCall_INextBot_GetLocomotionInterface = EndPrepSDKCall();

	StartPrepSDKCall( SDKCall_Raw );
	PREP_SDK_VCALL_SET_FROM_CONF_WRAPPER("INextBot::MySurvivorBotPointer")
	PrepSDKCall_SetReturnInfo( SDKType_CBaseEntity, SDKPass_Plain, VDECODE_FLAG_ALLOWNULL );
	g_hSDKCall_INextBot_MySurvivorBotPointer = EndPrepSDKCall();

	StartPrepSDKCall( SDKCall_Player );
	PREP_SDK_VCALL_SET_FROM_CONF_WRAPPER("NextBotPlayer<CTerrorPlayer>::MyNextBotPointer")
	PrepSDKCall_SetReturnInfo( SDKType_PlainOldData, SDKPass_Plain );
	g_hSDKCall_NextBotPlayer_CTerrorPlayer_MyNextBotPointer = EndPrepSDKCall();

	StartPrepSDKCall( SDKCall_Raw );
	PREP_SDK_VCALL_SET_FROM_CONF_WRAPPER("CBaseCombatCharacter::GetLastKnownArea")
	PrepSDKCall_SetReturnInfo( SDKType_PlainOldData, SDKPass_Plain );
	g_hSDKCall_CBaseCombatCharacter_GetLastKnownArea = EndPrepSDKCall();

	StartPrepSDKCall( SDKCall_Raw );
	PREP_SDK_VCALL_SET_FROM_CONF_WRAPPER("ILocomotion::Jump")
	g_hSDKCall_ILocomotion_Jump = EndPrepSDKCall();

	delete hGameData;

	for ( int iClient = 1; iClient <= MaxClients; iClient++ )
	{
		if ( IsClientInGame( iClient ) )
		{
			OnClientPutInServer( iClient );
		}
	}
}

public Plugin myinfo =
{
	name = "[L4D/2] Survivor Bot Nav Fixes",
	author = "Justin \"Jay\" Chellah",
	description = "Fixes issues where survivor bots would not respect areas marked as WALK, CROUCH, STOP, JUMP and NO_JUMP",
	version = "1.1.0",
	url = "https://github.com/jchellah/survivor_bot_nav_fixes"
};