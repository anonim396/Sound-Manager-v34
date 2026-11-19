#include <sourcemod>
#include <clientprefs>
#include <dhooks>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo =
{
	name = "Sound Manager",
	author = "Haze",
	description = "",
	version = "1.0.5",
	url = ""
}

#define Mute_Soundscapes				(1 << 0)
#define Mute_AmbientSounds				(1 << 1)
#define Mute_GunSounds					(1 << 2)
#define Mute_TriggerSounds				(1 << 3)
#define Mute_NormalSounds				(1 << 4)
#define Debug							(1 << 5)

#define Variant_FieldType_Offset		16
#define Variant_FieldType_String		2

// Engine
EngineVersion gEV_Type = Engine_Unknown;

// Player settings
int gI_Settings[MAXPLAYERS+1];
bool gB_AlreadyMuted[MAXPLAYERS+1];

// Debug
int gI_LastSoundscape[MAXPLAYERS+1];

// Cookie
Handle gH_SettingsCookie = null;

// DHooks
Address gP_SoundscapeSystem = Address_Null;
Handle gH_AcceptInput = null;
Handle gH_GetPlayerSlot = null;
Handle gH_GetStringID = null;
int gI_AmbientOffset = -1;
int gI_m_soundscapesOffset = -1;
int gI_VolumeOffset = -1;
int gI_CurrentSoundscapeOffset = -1;
int gI_CGameClientThing = -1;

#pragma unused gI_CurrentSoundscapeOffset

// Other
int gI_SilentSoundScape = -1;
char gS_WeaponID[32];

bool gB_ShouldHookShotgunShot = false;
ArrayList gA_LoopingAmbients = null;
bool gB_EntitiesFound = false;

// Late Load
bool gB_LateLoad = false;

//-----------------------FORWARDS-------------------------
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	gB_LateLoad = late;
	return APLRes_Success;
}

public void OnPluginStart()
{
	gEV_Type = GetEngineVersion();
	if(gEV_Type != Engine_SourceSDK2006)
	{
		SetFailState("This plugin is only supported for CSS v34 (Source SDK 2006).");
	}

	FormatEx(gS_WeaponID, sizeof(gS_WeaponID), "m_iWeaponID");

	// Translations
	LoadTranslations("SoundManager.phrases");

	// Commands
	RegConsoleCmd("sm_snd", Command_Sounds);
	RegConsoleCmd("sm_sound", Command_Sounds);
	RegConsoleCmd("sm_sounds", Command_Sounds);
	RegConsoleCmd("sm_music", Command_Sounds);
	RegConsoleCmd("sm_stopmusic", Command_Sounds);
	RegConsoleCmd("sm_stopsounds", Command_Sounds);

	// Cookie
	gH_SettingsCookie = RegClientCookie("sound_settings", "Sound Manager Settings", CookieAccess_Protected);

	gA_LoopingAmbients = new ArrayList(ByteCountToCells(4));

	// Hook round_start
	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

	// Dhooks
	LoadDHooks();

	// Sound Hook
	AddTempEntHook("Shotgun Shot", Hook_ShotgunShot);

	// Late Load
	if(gB_LateLoad)
	{
		int entity = -1;
		while((entity = FindEntityByClassname(entity, "point_clientcommand")) != -1)
		{
			DHookEntity(gH_AcceptInput, false, entity);
		}

		UpdateSilentSoundscape();
		Event_RoundStart(null, "", false);

		for(int i = 1; i <= MaxClients; i++)
		{
			if(IsValidClient(i) && AreClientCookiesCached(i))
			{
				OnClientCookiesCached(i);
			}
		}
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if(gH_AcceptInput == null)
	{
		return;
	}

	if(StrEqual(classname, "point_clientcommand"))
	{
		DHookEntity(gH_AcceptInput, false, entity);
	}
}

public void OnClientDisconnect_Post(int client)
{
	gB_AlreadyMuted[client] = false;
	gI_Settings[client] = 0;
	gI_LastSoundscape[client] = -1;
	CheckShotgunShotHook();
}

public void OnClientCookiesCached(int client)
{
	gI_LastSoundscape[client] = -1;

	if(!IsValidClient(client))
	{
		return;
	}

	char sCookie[16];
	GetClientCookie(client, gH_SettingsCookie, sCookie, sizeof(sCookie));
	gI_Settings[client] = StringToInt(sCookie);

	CheckShotgunShotHook();

	if(gI_Settings[client] & Mute_Soundscapes)
	{
		// Maybe auth can take a long time and a soundscape slips through...
		ClientCommand(client, "cl_soundscape_flush");
	}
}

public Action OnPlayerRunCmd(int client)
{
	if(!(gI_Settings[client] & (Mute_Soundscapes|Mute_AmbientSounds)))
	{
		return Plugin_Continue;
	}

	if(!IsValidClient(client))
	{
		return Plugin_Continue;
	}

	if(gI_Settings[client] & Mute_Soundscapes)
	{
		SetEntProp(client, Prop_Data, "soundscapeIndex", gI_SilentSoundScape);
	}

	if(!(gI_Settings[client] & Mute_AmbientSounds) || gB_AlreadyMuted[client] || !gB_EntitiesFound || gA_LoopingAmbients == null)
	{
		return Plugin_Continue;
	}

	for(int i = 0; i < gA_LoopingAmbients.Length; i++)
	{
		int entity = EntRefToEntIndex(gA_LoopingAmbients.Get(i));

		if(entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity) || !HasEntProp(entity, Prop_Data, "m_iszSound"))
		{
			continue;
		}

		char sSound[PLATFORM_MAX_PATH];
		GetEntPropString(entity, Prop_Data, "m_iszSound", sSound, sizeof(sSound));

		if(sSound[0] == '\0')
		{
			continue;
		}

		EmitSoundToClient(client, sSound, entity, SNDCHAN_STATIC, SNDLEVEL_NONE, SND_STOP, 0.0, SNDPITCH_NORMAL);

		if(gI_Settings[client] & Debug)
		{
			PrintToChat(client, "%t", "Debug Ambient Muted", sSound);
		}
	}

	gB_AlreadyMuted[client] = true;

	return Plugin_Continue;
}
//-------------------------------------------------------------

void LoadDHooks()
{
	GameData hGameData = LoadGameConfigFile("SoundManager.games");
	if(hGameData == null)
	{
		SetFailState("Failed to load SoundManager gamedata.");
	}

	StartPrepSDKCall_GetStringID(hGameData);
	HookAcceptInput();
	HookSendSound(hGameData);

	if((gI_AmbientOffset = hGameData.GetOffset("SoundInfo_t::bIsAmbient")) == -1)
	{
		SetFailState("Could not get SoundInfo_t::bIsAmbient offset");
	}

	if((gI_m_soundscapesOffset = hGameData.GetOffset("CSoundscapeSystem::m_soundscapes")) == -1)
	{
		SetFailState("Could not get CSoundscapeSystem::m_soundscapes offset");
	}

	if((gI_VolumeOffset = hGameData.GetOffset("SoundInfo_t::fVolume")) == -1)
	{
		SetFailState("Could not get SoundInfo_t::fVolume offset");
	}

	if((gI_CGameClientThing = hGameData.GetOffset("CGameClient::thing")) == -1)
	{
		SetFailState("Could not get CGameClient::thing");
	}

	delete hGameData;
}

//-------------------------SOUNDSCAPES-------------------------
void StartPrepSDKCall_GetStringID(GameData hGameData)
{
	gP_SoundscapeSystem = hGameData.GetAddress("CSoundscapeSystem");
	if(gP_SoundscapeSystem == Address_Null)
	{
		SetFailState("Could not get address of CSoundscapeSystem pointer.");
	}

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CStringRegistry::GetStringID");
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	gH_GetStringID = EndPrepSDKCall();
	if(gH_GetStringID == null)
	{
		SetFailState("Could not initialize call to CStringRegistry::GetStringID.");
	}
}

int GetSoundscapeIndex(const char[] sString)
{
	if(gH_GetStringID == null)
	{
		return -1;
	}

	return SDKCall(gH_GetStringID, gP_SoundscapeSystem + view_as<Address>(gI_m_soundscapesOffset), sString);
}

void UpdateSilentSoundscape()
{
	static const char sSilentSoundScapes[][] = {
		"port.LightHum2",
		"Nothing"
	};

	gI_SilentSoundScape = -1;

	if(gH_GetStringID == null)
	{
		return;
	}

	for(int i = 0; i < sizeof(sSilentSoundScapes); i++)
	{
		gI_SilentSoundScape = GetSoundscapeIndex(sSilentSoundScapes[i]);
		if(gI_SilentSoundScape != -1)
		{
			break;
		}
	}
}

public void OnMapStart()
{
	UpdateSilentSoundscape();
}
//---------------------------------------------------------------

//------------------------TRIGGER OUTPUTS------------------------
void HookAcceptInput()
{
	GameData hGameData = LoadGameConfigFile("sdktools.games");
	if(hGameData == null)
	{
		SetFailState("Failed to load sdktools gamedata.");
	}

	int offset = hGameData.GetOffset("AcceptInput");
	delete hGameData;

	if(offset == -1)
	{
		SetFailState("Failed to load \"AcceptInput\", invalid offset.");
	}

	gH_AcceptInput = DHookCreate(offset, HookType_Entity, ReturnType_Bool, ThisPointer_CBaseEntity, DHook_AcceptInput);
	DHookAddParam(gH_AcceptInput, HookParamType_CharPtr);
	DHookAddParam(gH_AcceptInput, HookParamType_CBaseEntity);
	DHookAddParam(gH_AcceptInput, HookParamType_CBaseEntity);
	DHookAddParam(gH_AcceptInput, HookParamType_Object, 20, DHookPass_ByVal|DHookPass_ODTOR|DHookPass_OCTOR|DHookPass_OASSIGNOP);
	DHookAddParam(gH_AcceptInput, HookParamType_Int);
}

// virtual bool AcceptInput( const char *szInputName, CBaseEntity *pActivator, CBaseEntity *pCaller, variant_t Value, int outputID );
public MRESReturn DHook_AcceptInput(int pThis, Handle hReturn, Handle hParams)
{
	if(DHookIsNullParam(hParams, 2))
	{
		return MRES_Ignored;
	}

	int client = DHookGetParam(hParams, 2);

	if(!IsValidClient(client))
	{
		return MRES_Ignored;
	}

	if(!(gI_Settings[client] & Mute_TriggerSounds))
	{
		return MRES_Ignored;
	}

	if(DHookGetParamObjectPtrVar(hParams, 4, Variant_FieldType_Offset, ObjectValueType_Int) != Variant_FieldType_String)
	{
		return MRES_Ignored;
	}

	char sParameter[128];
	DHookGetParamObjectPtrString(hParams, 4, 0, ObjectValueType_String, sParameter, sizeof(sParameter));

	char sExplode[1][128];
	ExplodeString(sParameter, " ", sExplode, sizeof(sExplode), sizeof(sExplode[]));

	if(StrEqual(sExplode[0], "play", false)
	|| StrEqual(sExplode[0], "playgamesound", false)
	|| StrEqual(sExplode[0], "play_hrtf", false)
	|| StrEqual(sExplode[0], "snd_playsounds", false))
	{
		if(gI_Settings[client] & Debug)
		{
			PrintToChat(client, "%t", "Debug Output Blocked", sParameter);
		}

		DHookSetReturn(hReturn, false);
		return MRES_Supercede;
	}

	return MRES_Ignored;
}
//-----------------------------------------------------

//----------------AMBIENT/NORMAL SOUNDS----------------
void HookSendSound(GameData hGameData)
{
	LogMessage("[SM-DBG] HookSendSound begin");

	// Log the address the signature/symbol resolves to
	Address pFunc = hGameData.GetAddress("CGameClient::SendSound");
	LogMessage("[SM-DBG] HookSendSound: CGameClient::SendSound resolved to 0x%X", view_as<int>(pFunc));

	Handle hFunction = DHookCreateDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Address);
	DHookSetFromConf(hFunction, hGameData, SDKConf_Signature, "CGameClient::SendSound");
	DHookAddParam(hFunction, HookParamType_ObjectPtr);
	DHookAddParam(hFunction, HookParamType_Bool);
	if(!DHookEnableDetour(hFunction, false, DHook_SendSound))
	{
		SetFailState("Couldn't enable CGameClient::SendSound detour.");
	}

	LogMessage("[SM-DBG] HookSendSound: detour enabled");

	StartPrepSDKCall(SDKCall_Raw);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CBaseClient::GetPlayerSlot");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	gH_GetPlayerSlot = EndPrepSDKCall();
	if(gH_GetPlayerSlot == null)
	{
		SetFailState("Could not initialize call to CBaseClient::GetPlayerSlot.");
	}

	LogMessage("[SM-DBG] HookSendSound: GetPlayerSlot ready");
}

/*struct SoundInfo_t
{
	int			 nSequenceNumber;   Offset: 0  | Size: 4
	int			 nEntityIndex;	  Offset: 4  | Size: 4
	int			 nChannel;		  Offset: 8  | Size: 4
	const char	  *pszName;		  Offset: 12 | Size: 4
	Vector		  vOrigin;		   Offset: 16 | Size: 12
	Vector		  vDirection;		Offset: 28 | Size: 12
	float		   fVolume;		   Offset: 40 | Size: 4
	soundlevel_t	Soundlevel;		Offset: 44 | Size: 4
	bool			bLooping;		  Offset: 48 | Size: 1
	int			 nPitch;			Offset: 52 | Size: 4
	int			 nSpecialDSP;	   Offset: 56 | Size: 4
	Vector		  vListenerOrigin;   Offset: 60 | Size: 12
	int			 nFlags;			Offset: 72 | Size: 4
	int			 nSoundNum;		 Offset: 76 | Size: 4
	float		   fDelay;			Offset: 80 | Size: 4
	bool			bIsSentence;	   Offset: 84 | Size: 1
	bool			bIsAmbient;		Offset: 85 | Size: 1
	int			 nSpeakerEntity;	Offset: 88 | Size: 4
};*/

//void CGameClient::SendSound( SoundInfo_t &sound, bool isReliable )
public MRESReturn DHook_SendSound(Address pThis, Handle hParams)
{
	if(DHookGetParamObjectPtrVar(hParams, 1, gI_VolumeOffset, ObjectValueType_Float) == 0.0)
	{
		return MRES_Ignored;
	}

	Address pIClient = pThis + view_as<Address>(gI_CGameClientThing);

	int client = view_as<int>(SDKCall(gH_GetPlayerSlot, pIClient)) + 1;

	if(!IsValidClient(client))
	{
		return MRES_Ignored;
	}

	bool bIsAmbient = DHookGetParamObjectPtrVar(hParams, 1, gI_AmbientOffset, ObjectValueType_Bool);

	if(gI_Settings[client] & (bIsAmbient ? Mute_AmbientSounds : Mute_NormalSounds))
	{
		if(gI_Settings[client] & Debug)
		{
			PrintToChat(client, "%t", bIsAmbient ? "Debug Ambient Blocked" : "Debug Sound Blocked");
		}

		return MRES_Supercede;
	}

	return MRES_Ignored;
}
//-----------------------------------------------------

//------------------------MENU-------------------------
public Action Command_Sounds(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	Menu menu = new Menu(MenuHandler_Sounds);
	menu.SetTitle("%t\n ", "Menu Title");

	char sDisplay[64];
	char sInfo[16];
	char sState[32];

	FormatEx(sState, sizeof(sState), "%t", (gI_Settings[client] & Mute_Soundscapes) ? "State Muted" : "State On");
	FormatEx(sDisplay, sizeof(sDisplay), "%t: [%s]", "Menu Soundscapes", sState);
	IntToString(Mute_Soundscapes, sInfo, sizeof(sInfo));
	menu.AddItem(sInfo, sDisplay);

	FormatEx(sState, sizeof(sState), "%t", (gI_Settings[client] & Mute_AmbientSounds) ? "State Muted" : "State On");
	FormatEx(sDisplay, sizeof(sDisplay), "%t: [%s]", "Menu Ambient Sounds", sState);
	IntToString(Mute_AmbientSounds, sInfo, sizeof(sInfo));
	menu.AddItem(sInfo, sDisplay);

	FormatEx(sState, sizeof(sState), "%t", (gI_Settings[client] & Mute_NormalSounds) ? "State Muted" : "State On");
	FormatEx(sDisplay, sizeof(sDisplay), "%t: [%s]", "Menu Normal Sounds", sState);
	IntToString(Mute_NormalSounds, sInfo, sizeof(sInfo));
	menu.AddItem(sInfo, sDisplay);

	FormatEx(sState, sizeof(sState), "%t", (gI_Settings[client] & Mute_TriggerSounds) ? "State Muted" : "State On");
	FormatEx(sDisplay, sizeof(sDisplay), "%t: [%s]\n ", "Menu Trigger Sounds", sState);
	IntToString(Mute_TriggerSounds, sInfo, sizeof(sInfo));
	menu.AddItem(sInfo, sDisplay);

	FormatEx(sState, sizeof(sState), "%t", (gI_Settings[client] & Mute_GunSounds) ? "State Muted" : "State On");
	FormatEx(sDisplay, sizeof(sDisplay), "%t: [%s]\n ", "Menu Gun Sounds", sState);
	IntToString(Mute_GunSounds, sInfo, sizeof(sInfo));
	menu.AddItem(sInfo, sDisplay);

	if(CheckCommandAccess(client, "soundmanager_debug", ADMFLAG_RCON))
	{
		FormatEx(sState, sizeof(sState), "%t", (gI_Settings[client] & Debug) ? "State Yes" : "State No");
		FormatEx(sDisplay, sizeof(sDisplay), "%t: [%s]", "Menu Debug Prints", sState);
		IntToString(Debug, sInfo, sizeof(sInfo));
		menu.AddItem(sInfo, sDisplay);
	}

	menu.Display(client, MENU_TIME_FOREVER);
	return Plugin_Handled;
}

public int MenuHandler_Sounds(Menu menu, MenuAction action, int param1, int param2)
{
	if(action == MenuAction_Select)
	{
		if(!IsClientInGame(param1))
		{
			return 0;
		}

		char sInfo[16];
		menu.GetItem(param2, sInfo, sizeof(sInfo));

		int iOption = StringToInt(sInfo);
		gI_Settings[param1] ^= iOption;

		if(iOption == Mute_GunSounds)
		{
			CheckShotgunShotHook();
		}
		else if(iOption == Mute_Soundscapes)
		{
			if(gI_Settings[param1] & Mute_Soundscapes)
			{
				ClientCommand(param1, "cl_soundscape_flush");
			}
		}
		else if(iOption == Mute_AmbientSounds)
		{
			gB_AlreadyMuted[param1] = false;
		}

		char sCookie[16];
		IntToString(gI_Settings[param1], sCookie, sizeof(sCookie));
		SetClientCookie(param1, gH_SettingsCookie, sCookie);

		Command_Sounds(param1, 0);
	}

	else if(action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}
//----------------------------------------------------

//-----------------------EVENTS-----------------------
public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	gB_EntitiesFound = false;

	if(gA_LoopingAmbients != null)
	{
		gA_LoopingAmbients.Clear();
	}

	for(int i = 1; i <= MaxClients; i++)
	{
		gB_AlreadyMuted[i] = false;
	}

	if(gI_SilentSoundScape == -1)
	{
		UpdateSilentSoundscape();
	}

	int entity = -1;
	while((entity = FindEntityByClassname(entity, "ambient_generic")) != -1)
	{
		if(GetEntProp(entity, Prop_Data, "m_fLooping") == 1)
		{
			gA_LoopingAmbients.Push(EntIndexToEntRef(entity));
		}
	}

	gB_EntitiesFound = true;
}
//----------------------------------------------------

// Credits to GoD-Tony for everything related to stopping gun sounds
public Action Hook_ShotgunShot(const char[] te_name, const int[] Players, int numClients, float delay)
{
	if(!gB_ShouldHookShotgunShot)
	{
		return Plugin_Continue;
	}

	// Check which clients need to be excluded.
	int newClients[MAXPLAYERS+1];
	int count = 0;

	for(int i = 0; i < numClients; i++)
	{
		int iClient = Players[i];

		// player not muting gun sounds
		if(!(gI_Settings[iClient] & Mute_GunSounds))
		{
			newClients[count] = iClient;
			count++;
		}
	}

	// No clients were excluded.
	if(count == numClients)
	{
		return Plugin_Continue;
	}
	// All clients were excluded and there is no need to broadcast.
	else if(count == 0)
	{
		return Plugin_Stop;
	}

	// Re-broadcast to clients that still need it.
	float vTemp[3];
	TE_Start("Shotgun Shot");
	TE_ReadVector("m_vecOrigin", vTemp);
	TE_WriteVector("m_vecOrigin", vTemp);
	TE_WriteFloat("m_vecAngles[0]", TE_ReadFloat("m_vecAngles[0]"));
	TE_WriteFloat("m_vecAngles[1]", TE_ReadFloat("m_vecAngles[1]"));
	TE_WriteNum(gS_WeaponID, TE_ReadNum(gS_WeaponID));
	TE_WriteNum("m_iMode", TE_ReadNum("m_iMode"));
	TE_WriteNum("m_iSeed", TE_ReadNum("m_iSeed"));
	TE_WriteNum("m_iPlayer", TE_ReadNum("m_iPlayer"));

	if(TE_IsValidProp("m_fInaccuracy"))
	{
		TE_WriteFloat("m_fInaccuracy", TE_ReadFloat("m_fInaccuracy"));
	}

	if(TE_IsValidProp("m_fSpread"))
	{
		TE_WriteFloat("m_fSpread", TE_ReadFloat("m_fSpread"));
	}

	TE_Send(newClients, count, delay);

	return Plugin_Stop;
}

void CheckShotgunShotHook()
{
	bool bShouldHook = false;

	for(int i = 1; i <= MaxClients; i++)
	{
		if(!IsClientInGame(i))
		{
			continue;
		}

		if(gI_Settings[i] & Mute_GunSounds)
		{
			bShouldHook = true;
			break;
		}
	}

	// Fake (un)hook because toggling actual hooks will cause server instability.
	gB_ShouldHookShotgunShot = bShouldHook;
}

bool IsValidClient(int client)
{
	return (client >= 1 && client <= MaxClients && IsClientInGame(client) && !IsClientSourceTV(client));
}