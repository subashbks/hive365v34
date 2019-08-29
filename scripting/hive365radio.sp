#include <sourcemod>
#include <socket>
#include <base64>
#include <json>

#pragma semicolon 1
#pragma newdecls required

//Defines
#define PLUGIN_VERSION		"4.0.5.6"
#define DEFAULT_RADIO_VOLUME	"15"
char RADIO_PLAYER_URL[]		=	"hive365.co.uk/plugin/player";
char CHAT_PREFIX[]			=	"\x03[\x04Hive365\x03]";

//Timer defines
#define INFO_REFRESH_RATE 30.0
#define HIVE_ADVERT_RATE 600.0
#define HELP_TIMER_DELAY 15.0

//Menu Handles
Menu menuHelp;
Menu menuVolume;
Menu menuTuned;

//Tracked Information
char szEncodedHostname[256];
char szEncodedHostPort[16];
char szCurrentSong[256];
char szCurrentDJ[64];
bool bIsTunedIn[MAXPLAYERS+1];

//CVars
ConVar convarEnabled;

//Voting Trie's
StringMap stringmapRate;
StringMap stringmapRequest;
StringMap stringmapShoutout;
StringMap stringmapDJFTW;

//enum's
enum RadioOptions
{
	Radio_On,
	Radio_Off,
	Radio_Volume,
	Radio_Help
};

enum SocketInfo
{
	SocketInfo_Info,
	SocketInfo_Request,
	SocketInfo_Shoutout,
	SocketInfo_Choon,
	SocketInfo_Poon,
	SocketInfo_DjFtw,
	SocketInfo_HeartBeat
};

char szEncodedHostip[128] = "";

public Plugin myinfo = 
{
	name = "Hive365 Player v34",
	author = "Hive365.co.uk, return 0;",
	description = "Hive365 In-Game Radio Player v34",
	version = PLUGIN_VERSION,
	url = "http://www.hive365.co.uk, https://github.com/subashbks/hive365v34"
}

public void OnPluginStart()
{
	stringmapRate = new StringMap();
	stringmapRequest = new StringMap();
	stringmapShoutout = new StringMap();
	stringmapDJFTW = new StringMap();
	
	RegConsoleCmd("sm_radio", Cmd_RadioMenu);
	RegConsoleCmd("sm_hive", Cmd_RadioMenu);
	RegConsoleCmd("sm_radiohelp", Cmd_RadioHelp);
	RegConsoleCmd("sm_hivehelp", Cmd_RadioHelp);
	RegConsoleCmd("sm_dj", Cmd_DjInfo);
	RegConsoleCmd("sm_song", Cmd_SongInfo);
	RegConsoleCmd("sm_shoutout", Cmd_Shoutout);
	RegConsoleCmd("sm_sh", Cmd_Shoutout);
	RegConsoleCmd("sm_request", Cmd_Request);
	RegConsoleCmd("sm_req", Cmd_Request);
	RegConsoleCmd("sm_choon", Cmd_Choon);
	RegConsoleCmd("sm_ch", Cmd_Choon);
	RegConsoleCmd("sm_poon", Cmd_Poon);
	RegConsoleCmd("sm_p", Cmd_Poon);
	RegConsoleCmd("sm_djftw", Cmd_DjFtw);
	
	convarEnabled = CreateConVar("sm_hive365radio_enabled", "1", "Enable the radio?", _, true, 0.0, true, 1.0);
	CreateConVar("sm_hive365radio_version", PLUGIN_VERSION, "Hive365 Radio Plugin Version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	AutoExecConfig();
	
	menuTuned = new Menu(RadioTunedMenuHandle);
	menuTuned.SetTitle("Hive365");
	menuTuned.AddItem("0", "Start Hive365");
	menuTuned.AddItem("1", "Stop Hive365");
	menuTuned.AddItem("2", "Hive365 Volume");
	menuTuned.AddItem("3", "Hive365 Help");
	menuTuned.ExitButton = true;
	
	menuVolume = new Menu(RadioVolumeMenuHandle);
	menuVolume.SetTitle("Hive365 Volume");
	menuVolume.AddItem("3", "Volume : 3%");
	menuVolume.AddItem("7", "Volume : 7%");
	menuVolume.AddItem("10", "Volume : 10%");
	menuVolume.AddItem("15", "Volume : 15% (Default)");
	menuVolume.AddItem("20", "Volume : 20%");
	menuVolume.AddItem("35", "Volume : 35%");
	menuVolume.AddItem("50", "Volume : 50%");
	menuVolume.AddItem("75", "Volume : 75%");
	menuVolume.AddItem("100", "Volume : 100%");
	menuVolume.Pagination = MENU_NO_PAGINATION;
	menuVolume.ExitButton = true;
	
	menuHelp = new Menu(HelpMenuHandle);
	menuHelp.SetTitle("Hive365 Help");
	menuHelp.AddItem("0", "Type !radio or !hive to tune in");
	menuHelp.AddItem("1", "Type !dj to get the dj info");
	menuHelp.AddItem("2", "Type !song to get the song info");
	menuHelp.AddItem("3", "Type !choon or !ch to like a song");
	menuHelp.AddItem("4", "Type !poon or !p to dislike a song");
	menuHelp.AddItem("5", "Type !request or !req to request a song");
	menuHelp.AddItem("6", "Type !shoutout or !sh to request a shoutout");
	menuHelp.Pagination = MENU_NO_PAGINATION;
	menuHelp.ExitButton = true;
	
	ConVar hostname = FindConVar("hostname");
	char szHostname[128];
	hostname.GetString(szHostname, sizeof(szHostname));
	EncodeBase64(szEncodedHostname, sizeof(szEncodedHostname), szHostname);
	hostname.AddChangeHook(HookHostnameChange);
	
	char szPort[6];
	FindConVar("hostport").GetString(szPort, sizeof(szPort));
	EncodeBase64(szEncodedHostPort, sizeof(szEncodedHostPort), szPort);
	
	MakeSocketRequest(SocketInfo_Info);
	
	CreateTimer(HIVE_ADVERT_RATE, ShowAdvert, _, TIMER_REPEAT);
	CreateTimer(INFO_REFRESH_RATE, GetStreamInfoTimer, _, TIMER_REPEAT);
	
	for(int i = 0; i <= MaxClients; i++)
		bIsTunedIn[i] = false;
}

public void OnMapStart()
{
	stringmapRate.Clear();
	stringmapRequest.Clear();
	stringmapShoutout.Clear();
	stringmapDJFTW.Clear();
	MakeSocketRequest(SocketInfo_HeartBeat);
}

public void OnClientDisconnect(int client)
{
	bIsTunedIn[client] = false;
}

public void OnClientPutInServer(int client)
{
	int serial = GetClientSerial(client);
	bIsTunedIn[client] = false;
	CreateTimer(HELP_TIMER_DELAY, HelpMessage, serial, TIMER_FLAG_NO_MAPCHANGE);
}

public void HookHostnameChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
	EncodeBase64(szEncodedHostname, sizeof(szEncodedHostname), newValue);
}

//Timer Handlers
public Action GetStreamInfoTimer(Handle timer)
{
	MakeSocketRequest(SocketInfo_Info);
}

public Action ShowAdvert(Handle timer)
{
	for(int i = 1; i <= MaxClients; i++)
		if(IsClientInGame(i) && !bIsTunedIn[i])
			PrintToChat(i, "%s This server is running \x04Hive365 Radio. \x03Type \x04!radiohelp \x03for Help!", CHAT_PREFIX);
}

public Action HelpMessage(Handle timer, any serial)
{
	int client = GetClientFromSerial(serial);
	if(client > 0 && client <= MaxClients && IsClientInGame(client))
		PrintToChat(client, "%s This server is running \x04Hive365 Radio. \x03Type \x04!radiohelp \x03for Help!", CHAT_PREFIX);	
	return Plugin_Continue;
}

//Command Handlers
public Action Cmd_DjFtw(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
		return Plugin_Handled;
	if(!HandleSteamIDTracking(stringmapDJFTW, client))
	{
		PrintToChat(client, "%s \x04You have already rated this DJFTW!", CHAT_PREFIX);
		return Plugin_Handled;
	}
	MakeSocketRequest(SocketInfo_DjFtw, GetClientSerial(client));
	return Plugin_Handled;
}

public Action Cmd_Shoutout(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
		return Plugin_Handled;
	if(args <= 0)
	{
		PrintToChat(client, "%s Type \x04!shoutout <shoutout> \x03or \x04!sh <shoutout>", CHAT_PREFIX);
		return Plugin_Handled;
	}
	if(!HandleSteamIDTracking(stringmapShoutout, client, true, 10))
	{
		PrintToChat(client, "%s \x04Please wait a few minutes between Shoutouts.", CHAT_PREFIX);
		return Plugin_Handled;
	}
	char buffer[128];
	GetCmdArgString(buffer, sizeof(buffer));
	if(strlen(buffer) > 3)
		MakeSocketRequest(SocketInfo_Shoutout, GetClientSerial(client), buffer);	
	return Plugin_Handled;
}

public Action Cmd_Choon(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
		return Plugin_Handled;
	if(!HandleSteamIDTracking(stringmapRate, client, true, 5))
	{
		PrintToChat(client, "%s \x04Please wait a few minutes between Choons and Poons", CHAT_PREFIX);
		return Plugin_Handled;
	}
	PrintToChatAll("%s \x04%N \x03thinks that \x04%s \x03is a \x04banging Choon!", CHAT_PREFIX, client, szCurrentSong);
	MakeSocketRequest(SocketInfo_Choon, GetClientSerial(client));
	return Plugin_Handled;
}

public Action Cmd_Poon(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
		return Plugin_Handled;
	if(!HandleSteamIDTracking(stringmapRate, client, true, 5))
	{
		PrintToChat(client, "%s \x04Please wait a few minutes between Choons and Poons", CHAT_PREFIX);
		return Plugin_Handled;
	}
	PrintToChatAll("%s \x04%N \x03thinks that \x04%s \x03is a bit of a \x04naff Poon!", CHAT_PREFIX, client, szCurrentSong);
	MakeSocketRequest(SocketInfo_Poon, GetClientSerial(client));
	return Plugin_Handled;
}

public Action Cmd_Request(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
		return Plugin_Handled;
	if(args <= 0)
	{
		PrintToChat(client, "%s Type \x04!request <request> \x03or \x04!req <request>", CHAT_PREFIX);
		return Plugin_Handled;
	}
	if(!HandleSteamIDTracking(stringmapRequest, client, true, 10))
	{
		PrintToChat(client, "%s \x04Please wait a few minutes between Requests", CHAT_PREFIX);
		return Plugin_Handled;
	}
	char buffer[128];
	GetCmdArgString(buffer, sizeof(buffer));
	if(strlen(buffer) > 3)
		MakeSocketRequest(SocketInfo_Request, GetClientSerial(client), buffer);	
	return Plugin_Handled;
}

public Action Cmd_RadioHelp(int client, int args)
{
	if(client > 0 && client <= MaxClients && IsClientInGame(client))
		menuHelp.Display(client, 30);
	return Plugin_Handled;
}

public Action Cmd_RadioMenu(int client, int args)
{
	if(client > 0 && client <= MaxClients && IsClientInGame(client))
		menuTuned.Display(client, 30);	
	return Plugin_Handled;
}

public Action Cmd_SongInfo(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
		return Plugin_Handled;
	PrintToChat(client, "%s Current Song is : \x04%s", CHAT_PREFIX, szCurrentSong);
	return Plugin_Handled;
}

public Action Cmd_DjInfo(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
		return Plugin_Handled;
	PrintToChat(client, "%s Your DJ is : \x04%s", CHAT_PREFIX, szCurrentDJ);
	return Plugin_Handled;
}

//Menu Handlers
public int RadioTunedMenuHandle(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select && IsClientInGame(client))
	{
		char radiooption[3];
		menu.GetItem(option, radiooption, sizeof(radiooption));
		switch(view_as<RadioOptions>(StringToInt(radiooption)))
		{
			case Radio_Volume:
			{
				if(client > 0 && client <= MaxClients && IsClientInGame(client))
					menuVolume.Display(client, 30);
			}
			case Radio_On:
			{
				if(client > 0 && client <= MaxClients && IsClientInGame(client))
					DisplayRadioMenu(client);
			}
			case Radio_Off:
			{
				if(bIsTunedIn[client])
				{
					PrintToChat(client, "%s \x04Hive365 Radio has been turned off. Thanks for listening!", CHAT_PREFIX);
					LoadMOTDPanel(client, "Thanks for listening", "about:blank");
					bIsTunedIn[client] = false;
				}
				else
					PrintToChat(client, "%s \x04Hive365 Radio is already off", CHAT_PREFIX);
			}
			case Radio_Help:
				Cmd_RadioHelp(client, 0);
		}
	}
}

public int RadioVolumeMenuHandle(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select && IsClientInGame(client))
	{
		char szVolume[10];
		menu.GetItem(option, szVolume, sizeof(szVolume));
		char szURL[sizeof(RADIO_PLAYER_URL) + 15];
		Format(szURL, sizeof(szURL), "%s?volume=%s", RADIO_PLAYER_URL, szVolume);
		LoadMOTDPanel(client, "Hive365", szURL);
		bIsTunedIn[client] = true;
	}
}

public int HelpMenuHandle(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select && IsClientInGame(client))
	{
		char radiooption[3];
		menu.GetItem(option, radiooption, sizeof(radiooption));
		switch(StringToInt(radiooption))
		{
			case 0:
				Cmd_RadioMenu(client, 0);
			case 1:
				Cmd_DjInfo(client, 0);
			case 2:
				Cmd_SongInfo(client, 0);
			case 3:
				Cmd_Choon(client, 0);
			case 4:
				Cmd_Poon(client, 0);
			case 5:
				Cmd_Request(client, 0);
			case 6:
				Cmd_Shoutout(client, 0);
		}
	}
}

//Functions
void DisplayRadioMenu(int client)
{
	if(convarEnabled.BoolValue)
	{
		if(!bIsTunedIn[client])
		{
			char szURL[sizeof(RADIO_PLAYER_URL) + 15];
			Format(szURL, sizeof(szURL), "%s?volume=%s", RADIO_PLAYER_URL, DEFAULT_RADIO_VOLUME);
			LoadMOTDPanel(client, "Hive365", szURL);
			bIsTunedIn[client] = true;
		}
	}
	else
		PrintToChat(client, "%s \x04Hive365 Radio is currently disabled", CHAT_PREFIX);
}

void LoadMOTDPanel(int client, const char [] title, const char [] page)
{
	if(client == 0  || !IsClientInGame(client))
		return;
	KeyValues kv = new KeyValues("data");
	kv.SetString("title", title);
	kv.SetNum("type", MOTDPANEL_TYPE_URL);
	kv.SetString("msg", page);
	ShowVGUIPanel(client, "info", kv, false);
	delete kv;
}

bool HandleSteamIDTracking(StringMap map, int client, bool checkTime = false, int timeCheck = 0)
{
	char steamid[32];
	
	if(!GetClientAuthId(client, AuthId_Engine, steamid, sizeof(steamid), true))
	{
		return false;
	}
	
	if(!checkTime)
	{
		int value;
		
		if(map.GetValue(steamid, value))
		{
			return false;
		}
		else
		{
			map.SetValue(steamid, 1, true);
			return true;
		}
	}
	else
	{
		float value;
		
		if(map.GetValue(steamid, value) && value+(timeCheck*60) > GetEngineTime())
		{
			return false;
		}
		else
		{
			map.SetValue(steamid, GetEngineTime(), true);
			return true;
		}
	}
}

void MakeSocketRequest(SocketInfo type, int serial = 0, const char [] buffer = "")
{
	Handle socket = SocketCreate(SOCKET_TCP, OnSocketError);
	
	DataPack pack = CreateDataPack();
	
	pack.WriteCell(view_as<any>(type));
	
	if(type == SocketInfo_HeartBeat)
	{
		SocketSetArg(socket, pack);
		SocketConnect(socket, OnSocketConnected, OnSocketReceive, OnSocketDisconnected, "data.hive365.co.uk", 80);
		return;
	}
	else if(type != SocketInfo_Info)
	{
		pack.WriteCell(serial);
		pack.WriteString(buffer);
	}
	
	SocketSetArg(socket, pack);
	
	if(type == SocketInfo_Info)
	{
		SocketConnect(socket, OnSocketConnected, OnSocketReceive, OnSocketDisconnected, "data.hive365.co.uk", 80);
	}
	else
	{
		SocketConnect(socket, OnSocketConnected, OnSocketReceive, OnSocketDisconnected, "www.hive365.co.uk", 80);
	}
}

void SendSocketRequest(Handle socket, char [] request, char [] host)
{
	char requestStr[2048];
	Format(requestStr, sizeof(requestStr), "GET /%s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n", request, host);
	
	SocketSend(socket, requestStr);
}

void ParseSocketInfo(char [] receivedData)
{
	char song[256] = "Unknown";
	char dj[64] = "AutoDj";
	
	//Get the actual json we need
	int startOfJson = StrContains(receivedData, "{\"status\":");
	
	if(startOfJson)
	{
		JSON jsonObject = json_decode(receivedData[startOfJson], _, strlen(receivedData[startOfJson])-1);
		
		if(jsonObject)
		{
			if(json_get_string(jsonObject, "artist_song", song, sizeof(song)))
			{
				DecodeHTMLEntities(song, sizeof(song));
				if(!StrEqual(song, szCurrentSong, false))
				{
					strcopy(szCurrentSong, sizeof(szCurrentSong), song);
					PrintToChatAll("%s Now Playing : \x04%s", CHAT_PREFIX, szCurrentSong);
				}
			}
			if(json_get_string(jsonObject, "title", dj, sizeof(dj)))
			{
				DecodeHTMLEntities(dj, sizeof(dj));
				if(!StrEqual(dj, szCurrentDJ, false))
				{
					strcopy(szCurrentDJ, sizeof(szCurrentDJ), dj);
					stringmapDJFTW.Clear();
					PrintToChatAll("%s Your DJ is : \x04%s", CHAT_PREFIX, szCurrentDJ);
				}
			}
			json_destroy(jsonObject);
		}
	}
}

void DecodeHTMLEntities(char [] str, int size)
{
	static char htmlEnts[][][] = 
	{
		{"&amp;", "&"},
		{"\\", ""},
		{"&lt;", "<"},
		{"&gt;", ">"}
	};
	
	for(int i = 0; i < 4; i++)
	{
		ReplaceString(str, size, htmlEnts[i][0], htmlEnts[i][1], false);
	}
}

//Socket Handlers
#pragma newdecls optional

public OnSocketConnected(Handle socket, any pack) 
{
	char urlRequest[1024];
	(view_as<DataPack>(pack)).Reset();
	
	SocketInfo type = view_as<SocketInfo>((view_as<DataPack>(pack)).ReadCell());
	
	if(type == SocketInfo_HeartBeat)
	{
		char buffer[64];
		
		EncodeBase64(buffer, sizeof(buffer), PLUGIN_VERSION);
		
		Format(urlRequest, sizeof(urlRequest), "addServer.php?port=%s&version=%s%s", szEncodedHostPort, buffer, szEncodedHostip);
		
		SendSocketRequest(socket, urlRequest, "data.hive365.co.uk");
		return;
	}
	else if(type == SocketInfo_Info)
	{
		SendSocketRequest(socket, "stream/info.php", "data.hive365.co.uk");
		return;
	}
	else
	{
		int client = GetClientFromSerial((view_as<DataPack>(pack)).ReadCell());
		char name[MAX_NAME_LENGTH];
		char szEncodedName[128];
		char szEncodedData[256];

		if(client == 0 || !IsClientInGame(client) || !GetClientName(client, name, sizeof(name)))
		{
			return;
		}
		
		EncodeBase64(szEncodedName, sizeof(szEncodedName), name);
		
		if(type == SocketInfo_Request || type == SocketInfo_Shoutout || type == SocketInfo_DjFtw)
		{
			if(type == SocketInfo_DjFtw)
			{
				EncodeBase64(szEncodedData, sizeof(szEncodedData), szCurrentDJ);
			}
			else
			{
				char buffer[128];
				
				(view_as<DataPack>(pack)).ReadString(buffer, sizeof(buffer));
				EncodeBase64(szEncodedData, sizeof(szEncodedData), buffer);
			}
			
			if(type == SocketInfo_DjFtw)
			{
				Format(urlRequest, sizeof(urlRequest), "plugin/djrate.php?n=%s&s=%s&host=%s", szEncodedName, szEncodedData, szEncodedHostname);
			}
			else if(type == SocketInfo_Shoutout)
			{
				Format(urlRequest, sizeof(urlRequest), "plugin/shoutout.php?n=%s&s=%s&host=%s", szEncodedName, szEncodedData, szEncodedHostname);
			}
			else
			{
				Format(urlRequest, sizeof(urlRequest), "plugin/request.php?n=%s&s=%s&host=%s", szEncodedName, szEncodedData, szEncodedHostname);
			}
		}
		else if(type == SocketInfo_Choon)
		{
			Format(urlRequest, sizeof(urlRequest), "plugin/song_rate.php?n=%s&t=3&host=%s", szEncodedName, szEncodedHostname);
		}
		else if(type == SocketInfo_Poon)
		{
			Format(urlRequest, sizeof(urlRequest), "plugin/song_rate.php?n=%s&t=4&host=%s", szEncodedName, szEncodedHostname);
		}
		
		SendSocketRequest(socket, urlRequest, "www.hive365.co.uk");
		return;
	}

}

public OnSocketReceive(Handle socket, char [] receivedData, const int dataSize, any pack) 
{
	(view_as<DataPack>(pack)).Reset();
	SocketInfo type = view_as<SocketInfo>((view_as<DataPack>(pack)).ReadCell());
	
	if(type == SocketInfo_Info)
	{
		ParseSocketInfo(receivedData);
	}
}

public OnSocketDisconnected(Handle socket, any pack) 
{
	(view_as<DataPack>(pack)).Reset();
	SocketInfo type = view_as<SocketInfo>((view_as<DataPack>(pack)).ReadCell());
	
	if(type == SocketInfo_Request || type == SocketInfo_Shoutout || type == SocketInfo_DjFtw)
	{
		int client = GetClientFromSerial((view_as<DataPack>(pack)).ReadCell());
		
		if(client != 0 && IsClientInGame(client))
		{
			if(type == SocketInfo_DjFtw)
			{
				PrintToChatAll("%s \x04%N thinks \x03%s is a \x04banging DJ!", CHAT_PREFIX, client, szCurrentDJ);
			}
			else if(type == SocketInfo_Shoutout)
			{
				PrintToChat(client, "%s \x04Your Shoutout has been sent!", CHAT_PREFIX);
			}
			else
			{
				PrintToChat(client, "%s \x04Your Request has been sent!", CHAT_PREFIX);
			}
		}
	}
	
	delete view_as<DataPack>(pack);
	delete socket;
}

public OnSocketError(Handle socket, const int errorType, const int errorNum, any pack) 
{
	(view_as<DataPack>(pack)).Reset();
	SocketInfo type = view_as<SocketInfo>((view_as<DataPack>(pack)).ReadCell());
	
	if(type == SocketInfo_Info)
	{
		strcopy(szCurrentSong, sizeof(szCurrentSong), "Unknown");
		strcopy(szCurrentDJ, sizeof(szCurrentDJ), "AutoDj");
	}
	LogError("[Hive365] socket error %d (errno %d)", errorType, errorNum);
	
	delete view_as<DataPack>(pack);
	delete socket;
}