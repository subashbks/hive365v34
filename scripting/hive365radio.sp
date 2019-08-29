#include <sourcemod>
#include <socket>
#include <base64>
#include <json>

#undef REQUIRE_PLUGIN
#include <updater>

#define UPDATE_URL    "http://hive365.co.uk/plugin/updatefile.txt"

#pragma semicolon 1
#pragma newdecls required

//Defines
#define PLUGIN_VERSION	"4.0.5"
char RADIO_PLAYER_URL[] = "http://hive365.co.uk/plugin/player/player_manual.html";
#define DEFAULT_RADIO_VOLUME 20

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
	Radio_Volume,
	Radio_Off,
	Radio_Help,
};

enum SocketInfo
{
	SocketInfo_Info,
	SocketInfo_Request,
	SocketInfo_Shoutout,
	SocketInfo_Choon,
	SocketInfo_Poon,
	SocketInfo_DjFtw,
	SocketInfo_HeartBeat,
};

char szEncodedHostip[128] = "";

public Plugin myinfo = 
{
	name = "Hive365 Player",
	author = "Hive365.co.uk",
	description = "Hive365 In-Game Radio Player",
	version = PLUGIN_VERSION,
	url = "http://www.hive365.co.uk"
}

public void OnPluginStart()
{
	stringmapRate = new StringMap();
	stringmapRequest = new StringMap();
	stringmapShoutout = new StringMap();
	stringmapDJFTW = new StringMap();
	
	RegConsoleCmd("sm_radio", Cmd_RadioMenu);
	RegConsoleCmd("sm_radiohelp", Cmd_RadioHelp);
	RegConsoleCmd("sm_dj", Cmd_DjInfo);
	RegConsoleCmd("sm_song", Cmd_SongInfo);
	RegConsoleCmd("sm_shoutout", Cmd_Shoutout);
	RegConsoleCmd("sm_request", Cmd_Request);
	RegConsoleCmd("sm_choon", Cmd_Choon);
	RegConsoleCmd("sm_poon", Cmd_Poon);
	RegConsoleCmd("sm_req", Cmd_Request);
	RegConsoleCmd("sm_ch", Cmd_Choon);
	RegConsoleCmd("sm_p", Cmd_Poon);
	RegConsoleCmd("sm_sh", Cmd_Shoutout);
	RegConsoleCmd("sm_djftw", Cmd_DjFtw);
	
	convarEnabled = CreateConVar("sm_hive365radio_enabled", "1", "Enable the radio?", _, true, 0.0, true, 1.0);
	CreateConVar("sm_hive365radio_version", PLUGIN_VERSION, "Hive365 Radio Plugin Version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY|FCVAR_DONTRECORD);
	AutoExecConfig();
	
	menuTuned = new Menu(RadioTunedMenuHandle);
	menuTuned.SetTitle("Radio Options");
	//menuTuned.AddItem("0", "Adjust Volume");
	menuTuned.AddItem("0", "Start Radio (Will open motd window to play and adjust volume)");
	menuTuned.AddItem("1", "Stop Radio");
	menuTuned.AddItem("2", "Radio Help");
	menuTuned.ExitButton = true;
	
	menuVolume = new Menu(RadioVolumeMenuHandle);
	menuVolume.SetTitle("Radio Options");
	menuVolume.AddItem("1", "Volume: 1%");
	menuVolume.AddItem("5", "Volume: 5%");
	menuVolume.AddItem("10", "Volume: 10%");
	menuVolume.AddItem("20", "Volume: 20% (default)");
	menuVolume.AddItem("30", "Volume: 30%");
	menuVolume.AddItem("40", "Volume: 40%");
	menuVolume.AddItem("50", "Volume: 50%");
	menuVolume.AddItem("75", "Volume: 75%");
	menuVolume.AddItem("100", "Volume: 100%");
	if(GetEngineVersion() != Engine_CSGO)// We could remove one for csgo maybe
	{
		menuVolume.Pagination = MENU_NO_PAGINATION;
	}
	menuVolume.ExitButton = true;
	
	menuHelp = new Menu(HelpMenuHandle);
	menuHelp.SetTitle("Radio Help");
	menuHelp.AddItem("0", "Type !radio in chat to tune in");
	menuHelp.AddItem("1", "Type !dj in chat to get dj info");
	menuHelp.AddItem("2", "Type !song in chat to get the song info");
	menuHelp.AddItem("3", "Type !choon in chat if you like a song");
	menuHelp.AddItem("4", "Type !poon in chat if you dislike a song");
	menuHelp.AddItem("-1", "Type !request song name in chat to request a song");
	menuHelp.AddItem("-1", "Type !shoutout shoutout in chat to request a shoutout");
	menuHelp.AddItem("-1", "NOTE: Currently broken for CS:GO");
	menuHelp.AddItem("-1", "NOTE: You must have HTML MOTD enabled!");
	menuHelp.Pagination = MENU_NO_PAGINATION;
	menuHelp.ExitButton = true;
	
	ConVar hostname = FindConVar("hostname");
	
	if(hostname)
	{
		char szHostname[128];
		hostname.GetString(szHostname, sizeof(szHostname));
		EncodeBase64(szEncodedHostname, sizeof(szEncodedHostname), szHostname);
		hostname.AddChangeHook(HookHostnameChange);
	}
	
	char szPort[10];
	FindConVar("hostport").GetString(szPort, sizeof(szPort));
	EncodeBase64(szEncodedHostPort, sizeof(szEncodedHostPort), szPort);
	
	ConVar showInfo = FindConVar("host_info_show");//CS:GO Only... for now
	if(showInfo)
	{
		if(showInfo.IntValue < 1)
		{
			showInfo.IntValue = 1;
		}
		showInfo.AddChangeHook(HookShowInfo);
	}
	
	MakeSocketRequest(SocketInfo_Info);
	
	CreateTimer(HIVE_ADVERT_RATE, ShowAdvert, _, TIMER_REPEAT);
	CreateTimer(INFO_REFRESH_RATE, GetStreamInfoTimer, _, TIMER_REPEAT);
	
	for(int i = 0; i <= MaxClients; i++){bIsTunedIn[i] = false;}
	
	
	if (LibraryExists("updater"))
	{
		Updater_AddPlugin(UPDATE_URL);
	}
}

public void OnLibraryAdded(const char[] name)
{
    if (StrEqual(name, "updater"))
    {
        Updater_AddPlugin(UPDATE_URL);
    }
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

public void HookShowInfo(ConVar convar, const char[] oldValue, const char[] newValue)
{
	if(convar.IntValue < 1)
	{
		convar.IntValue = 1;
	}
}

//Timer Handlers
public Action GetStreamInfoTimer(Handle timer)
{
	MakeSocketRequest(SocketInfo_Info);
}

public Action ShowAdvert(Handle timer)
{	
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientInGame(i) && !bIsTunedIn[i])
		{
			PrintToChat(i, "\x01[\x04Hive365\x01] \x04This server is running Hive365 Radio type !radiohelp for Help!");
		}
	}
}

public Action HelpMessage(Handle timer, any serial)
{
	int client = GetClientFromSerial(serial);
	if(client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		PrintToChat(client, "\x01[\x04Hive365\x01] \x04This server is running Hive365 Radio type !radiohelp for Help!");
	}
	
	return Plugin_Continue;
}

//Command Handlers
public Action Cmd_DjFtw(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}
	
	if(!HandleSteamIDTracking(stringmapDJFTW, client))
	{
		ReplyToCommand(client, "\x01[\x04Hive365\x01] \x04You have already rated this DJFTW!");
		return Plugin_Handled;
	}
	
	MakeSocketRequest(SocketInfo_DjFtw, GetClientSerial(client));
	
	return Plugin_Handled;
}

public Action Cmd_Shoutout(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}
	
	if(args <= 0)
	{
		ReplyToCommand(client, "\x01[\x04Hive365\x01] \x04sm_shoutout <shoutout> or !shoutout <shoutout>");
		return Plugin_Handled;
	}
	
	if(!HandleSteamIDTracking(stringmapShoutout, client, true, 10))
	{
		ReplyToCommand(client, "\x01[\x04Hive365\x01] \x04Please wait a few minutes between Shoutouts.");
		return Plugin_Handled;
	}
	
	char buffer[128];
	GetCmdArgString(buffer, sizeof(buffer));
	
	if(strlen(buffer) > 3)
	{
		MakeSocketRequest(SocketInfo_Shoutout, GetClientSerial(client), buffer);
	}
	
	return Plugin_Handled;
}

public Action Cmd_Choon(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}
	
	if(!HandleSteamIDTracking(stringmapRate, client, true, 5))
	{
		ReplyToCommand(client, "\x01[\x04Hive365\x01] \x04Please wait a few minutes between Choons and Poons");
		return Plugin_Handled;
	}
	
	PrintToChatAll("\x01[\x04Hive365\x01] \x04%N thinks that %s is a banging Choon!", client, szCurrentSong);
	
	MakeSocketRequest(SocketInfo_Choon, GetClientSerial(client));
	
	return Plugin_Handled;
}

public Action Cmd_Poon(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}
	
	if(!HandleSteamIDTracking(stringmapRate, client, true, 5))
	{
		ReplyToCommand(client, "\x01[\x04Hive365\x01] \x04Please wait a few minutes between Choons and Poons");
		return Plugin_Handled;
	}
	
	PrintToChatAll("\x01[\x04Hive365\x01] \x04%N thinks that %s  is a bit of a naff Poon!", client, szCurrentSong);
	
	MakeSocketRequest(SocketInfo_Poon, GetClientSerial(client));
	
	return Plugin_Handled;
}

public Action Cmd_Request(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}
	
	if(args <= 0)
	{
		ReplyToCommand(client, "\x01[\x04Hive365\x01] \x04sm_request <request> or !request <request>");
		return Plugin_Handled;
	}
	
	if(!HandleSteamIDTracking(stringmapRequest, client, true, 10))
	{
		ReplyToCommand(client, "\x01[\x04Hive365\x01] \x04Please wait a few minutes between Requests");
		return Plugin_Handled;
	}
	
	char buffer[128];
	GetCmdArgString(buffer, sizeof(buffer));
	
	if(strlen(buffer) > 3)
	{
		MakeSocketRequest(SocketInfo_Request, GetClientSerial(client), buffer);
	}
	
	return Plugin_Handled;
}

public Action Cmd_RadioHelp(int client, int args)
{
	if(client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		menuHelp.Display(client, 30);
	}
	
	return Plugin_Handled;
}

public Action Cmd_RadioMenu(int client, int args)
{
	if(client > 0 && client <= MaxClients && IsClientInGame(client))
	{
		menuTuned.Display(client, 30);
		//DisplayRadioMenu(client);
	}
	
	return Plugin_Handled;
}

public Action Cmd_SongInfo(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}
		
	ReplyToCommand(client, "\x01[\x04Hive365\x01] \x04Current Song is: %s", szCurrentSong);
	
	return Plugin_Handled;
}

public Action Cmd_DjInfo(int client, int args)
{
	if(client == 0 || !IsClientInGame(client))
	{
		return Plugin_Handled;
	}
		
	ReplyToCommand(client, "\x01[\x04Hive365\x01] \x04Your DJ is: %s", szCurrentDJ);
	
	return Plugin_Handled;
}

//Menu Handlers
public int RadioTunedMenuHandle(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select && IsClientInGame(client))
	{
		char radiooption[3];
		if(!menu.GetItem(option, radiooption, sizeof(radiooption)))
		{
			PrintToChat(client, "\x01[\x04Hive365\x01] \x04Unknown option selected");
		}
		switch(view_as<RadioOptions>(StringToInt(radiooption)))
		{
			case Radio_Volume:
			{
				if(client > 0 && client <= MaxClients && IsClientInGame(client))
				{
					DisplayRadioMenu(client);
				}
				//menuVolume.Display(client, 30);
			}
			case Radio_Off:
			{
				if(bIsTunedIn[client])
				{
					PrintToChat(client, "\x01[\x04Hive365\x01] \x04Radio has been turned off. Thanks for listening!");
					
					LoadMOTDPanel(client, "Thanks for listening", "about:blank", false);
					
					bIsTunedIn[client] = false;
				}
			}
			case Radio_Help:
			{
				menuHelp.Display(client, 30);
			}
		}
	}
}

public int RadioVolumeMenuHandle(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select && IsClientInGame(client))
	{
		char szVolume[10];
		
		if(!menu.GetItem(option, szVolume, sizeof(szVolume)))
		{
			PrintToChat(client, "\x01[\x04Hive365\x01] \x04Unknown option selected.");
		}
		
		char szURL[sizeof(RADIO_PLAYER_URL) + 15];
		
		Format(szURL, sizeof(szURL), RADIO_PLAYER_URL);
	
		LoadMOTDPanel(client, "Hive365", szURL, false);
		
		bIsTunedIn[client] = true;
	}
}

public int HelpMenuHandle(Menu menu, MenuAction action, int client, int option)
{
	if(action == MenuAction_Select && IsClientInGame(client))
	{
		char radiooption[3];
		if(!menu.GetItem(option, radiooption, sizeof(radiooption)))
		{
			PrintToChat(client, "\x01[\x04Hive365\x01] \x04Unknown option selected.");
		}
		
		switch(StringToInt(radiooption))
		{
			case 0:
			{
				Cmd_RadioMenu(client, 0);
			}
			case 1:
			{
				Cmd_DjInfo(client, 0);
			}
			case 2:
			{
				Cmd_SongInfo(client, 0);
			}
			case 3:
			{
				Cmd_Choon(client, 0);
			}
			case 4:
			{
				Cmd_Poon(client, 0);
			}
		}
	}
}

//Functions
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

void DisplayRadioMenu(int client)
{
	if(convarEnabled.BoolValue)
	{
		if(!bIsTunedIn[client])
		{
			char szURL[sizeof(RADIO_PLAYER_URL) + 15];
			
			Format(szURL, sizeof(szURL), RADIO_PLAYER_URL);
			
			LoadMOTDPanel(client, "Hive365", szURL, true);
			
			bIsTunedIn[client] = true;
		}
	}
	else
	{
		PrintToChat(client, "\x01 \x04[Hive365] Hive365 is currently disabled");
	}
}

void LoadMOTDPanel(int client, const char [] title, const char [] page, bool display)
{
	if(client == 0  || !IsClientInGame(client))
		return;
	
	KeyValues kv = new KeyValues("data");

	kv.SetString("title", title);
	kv.SetNum("type", MOTDPANEL_TYPE_URL);
	kv.SetString("msg", page);

	ShowVGUIPanel(client, "info", kv, display);
	
	delete kv;
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
					PrintToChatAll("\x01[\x04Hive365\x01] \x04Now Playing: %s", szCurrentSong);
				}
			}
			if(json_get_string(jsonObject, "title", dj, sizeof(dj)))
			{
				DecodeHTMLEntities(dj, sizeof(dj));
				if(!StrEqual(dj, szCurrentDJ, false))
				{
					strcopy(szCurrentDJ, sizeof(szCurrentDJ), dj);
					stringmapDJFTW.Clear();
					PrintToChatAll("\x01[\x04Hive365\x01] \x04Your DJ is: %s", szCurrentDJ);
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
				PrintToChatAll("\x01[\x04Hive365\x01] \x04%N thinks %s is a banging DJ!", client, szCurrentDJ);
			}
			else if(type == SocketInfo_Shoutout)
			{
				PrintToChat(client, "\x01[\x04Hive365\x01] \x04Your Shoutout has been sent!");
			}
			else
			{
				PrintToChat(client, "\x01[\x04Hive365\x01] \x04Your Request has been sent!");
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