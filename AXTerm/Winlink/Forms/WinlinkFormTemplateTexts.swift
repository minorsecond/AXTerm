// Template texts from the Winlink Standard Templates pack v1.1.20.0
// (winlink.org, freely distributed for Winlink use), embedded verbatim so
// generated message bodies match Winlink Express byte-for-byte semantics.
import Foundation

nonisolated enum WinlinkFormTemplateTexts {
    static let checkin = """
Form:Winlink_Check_In_Initial.html,Winlink_Check_In_Viewer.html
To:<var MsgTo>
Subject: <var Newsubject>
Readonly:True
Msg:
Winlink Check-in 
0. HEADER
  0a: Organization:	<var Organization>
  0b: Subject:	<var Newsubject>
  0c: Event/Exercise ID: <var exercise_id>

1. STATION
  1a. Date/Time:	<var DateTime>
  1b. To:	<var MsgTo>
  1c. From:	<var MsgSender>  
  1d. Station Contact Name:	<var ContactName>
  1e. Initial Operators:	<var Assigned>

2. SESSION
  2a. Type:	<var Status>
  2b. Service:	<var Service>
  2c. Band:	<var Band>
  2d. Session:	<var Session>

3. LOCATION
  3a. Location:	<var Location>
  3b. Latitude:	<var mapLat> 
  3c. Longitude:	<var mapLon>    
  3d. MGRS:	<var MGRS> 
  3e. Grid Square:	<var Grid>
  3f. Location sources:	<var locationSource>
-------------------------------------------------------------
4a COMMENTS:

<var Comments>  


-------------------------------------------------------------

<var Templateversion>
Map file name: <var Mapfilename>

[No changes or editing of this message are allowed]
----

"""

    static let checkout = """
Form:Winlink_Check_out_Initial.html,Winlink_Check_out_Viewer.html
To:<var MsgTo>
Subject: <var Newsubject>
Readonly:True
Msg:
Winlink Check-out 
0. HEADER
  0a: Organization:	<var Organization>
  0b: Subject:	<var Newsubject>
  0c: Event/Exercise ID:<var exercise_id>

1. STATION
  1a. Date/Time:	<var DateTime>
  1b. To:	<var MsgTo>
  1c. From:	<var MsgSender>  
  1d. Station Contact Name:	<var ContactName>
  1e. Initial Operators:	<var Assigned>

2. SESSION
  2a. Type:	<var Status>
  2b. Service:	<var Service>
  2c. Band:	<var Band>
  2d. Session:	<var Session>

3. LOCATION
  3a. Location:	<var Location>
  3b. Latitude:	<var mapLat> 
  3c. Longitude:	<var mapLon>    
  3d. MGRS:	<var MGRS> 
  3e. Grid Square:	<var Grid>
  3f. Location source:	<var locationSource>

-------------------------------------------------------------
4a COMMENTS:

<var Comments>  


-------------------------------------------------------------

<var Templateversion>
Map file name: <var Mapfilename>

[No changes or editing of this message are allowed]
----

"""

    static let ics213 = """
Form:ICS213_Initial.html,ICS213_Initial_Viewer.html
ReplyTemplate:ICS213_SendReply.0

To: 
Subject:ICS-213: <var Subjectline> - <var Mdate> <var mtime>

SeqInc:
Readonly:True
Msg:
GENERAL MESSAGE (ICS 213)
<var FormTitle>
<var IsExercise> 
1. Incident Name: <var inc_name>       <var txtStr> 
2. To (Name and Position): <var To_Name>
3. From (Name and Position): <var fm_name>
4. Subject: <var Subjectline>
5. Date: <var Mdate>
6. Time: <var mtime>
7. Message: 

<var Message>

8. Approved by: <var Approved_Name>
8a. Position/Title: <var Approved_PosTitle>
    [Sender: <var theMsgSender> Lat: <var mapLat>, Lon:<var mapLon>, MGRS: <var MGRS>; Location source: <var locationSource>]
------------------------------------
Express Sending Station: <MsgSender>
Senders Express Version: <ProgramVersion>
Senders Template Version: <var Templateversion>
[No changes or editing of this message are allowed]

"""

    static let fsr = """
Form:Field Situation Report Initial.html,Field Situation Report viewer.html 
To: <var MsgTo>
Cc: <var MsgCc>
Readonly:True
Subject://WL2K <var Precedence>/ Field Situation Report <var UDTGfld>

Readonly:True
Msg:

PRECEDENCE: <var Precedence>   
DATE/TIME Group: <var UDTGfld>   
TASK# <var MsgNR>
AGENCY: <var Title>
FROM: <var MsgSender>
TO: <var MsgTo>
INFO (CC): <var MsgCc>
BT
UNCLASS

SUBJ: Field Situation Report <var UDTGfld> 

1.EMERGENT/LIFE SAFETY Need <var Safetyneed>
Needs: <var Comm0>

2. City:<var City>  County:<var County> State: <var State> Territory:<var Territory>
3. Latitude:<var gpsLat>  Longitude:<var gpsLon>   MGRS:<var MGRS>  Location source:<var locationSource>
4a. POTS landlines functioning: [ <var k4> ]  <var Comm1>
4b. VOIP landlines functioning: [ <var k4A> ]  <var Comm1A>
5a. Cell phone voice calls functioning: [<var k5> ]  <var Comm2>
5b. Cell phone phone texts functioning: [<var k5A> ]   <var Comm2A>
6. AM/FM Broadcast Stations functioning: [ <var AMFM> ]  <var Comm3>
7a. OTA TV functioning: [ <var TVStatus> ]  <var Comm4>
7b. Satellite TV functioning: [ <var TVStatusb> ]  <var Comm4b>
7c. Cable TV  functioning:[ <var TVStatusc> ]  <var Comm4c>
8. Public Water Works functioning: [ <var WaterWorks> ]  <var Comm5>
9a. Commercial Power functioning: [ <var k9> ]  <var Comm6>
9b. Commercial Power Stable: [ <var k9A> ] <var Comm6A>
9c. Natural Gas Supply functioning: [ <var kgc9> ] <var Comm9c>
10. Internet functioning: [ <var Inter> ] <var Comm7>
11a. NOAA Weather Radio functioning: [ <var NOAA> ]  <var NOAAcom>
11b. NOAA Weather Radio Audio degraded: [ <var NOAAb> ]  <var NOAAcomb>
12. Additional Comments:  <var Message>
13. POC <var POC>

BT
NNNN

[No changes or editing of this message are allowed]

------------------------------------
Express Sending Station: <MsgSender>
Express Version: <ProgramVersion>
Template Version: <var Templateversion>
Map File Name: <var mapfilename>




"""

    static let severewx = """
Form:Severe WX Report.html,Severe WX Report viewer.html

To:
Subject: Severe WX Report <var Region> <var County> [<var Type>]

Msg:
Severe WX Report <var Region> <var County> 
Report Date/Time: <var DateTime>
Report Status: [<var Type>]
Message Sender: <var Call>
Reporting Party: <var RepName>
Phone Number: <var Phone>
Email: <var Email>

EVENT AREA
State or Region: <var Region>
County: <var County>
City: <var City>
Other: <var Other>
Coordinates: LAT: <var mapLat>  LON: <var mapLon>
MGRS: <var MGRS>   Location source: <var locationSource>


OBSERVED EVENT CONDITIONS

Flood: <var Flood>
Hail: <var HailSize> 
High Wind Speed:  <var WindspeedI> Mph | <var WindspeedM> KM/h
Tornado / Funnel Cloud: <var Tornado>
Wind Damage: <var WindDamage>
Winter Precipitation: <var Precipitation>
Snow:: <var SnowI> in. | <var SnowM> cm.
Freezing Rain: <var FreezingRainI> in. | <var FreezingRainM> mm.
Heavy Rain: <var RainI> in. | <var RainM> mm.
Rain period: <var RainPeriod>  hour

Additional Information or Comments:

<var Comments>

------------------------------------
Express Sending Station: <MsgSender>
Senders Express Version: <ProgramVersion> 
Senders Template Version: <var Templateversion>
Map File Name:  <var Mapfilename>


"""

    static let gps = """
Form:GPS Position Report.html
To: QTH
Sender: <Callsign>
From: <Callsign>
Subject: Position Report

Msg:
Time: <var thetime> 
Latitude: <var Lat>
Longitude: <var Lon>
Comment: <var Message>

"""

}
