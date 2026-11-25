{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

{
  HD Audio codecs: talking to them, and finding paths through them.

  Commands go through the controller's immediate command interface, one
  verb at a time, polled. A codec's audio function group holds widgets
  wired together by connection lists. An output path runs from an audio
  output converter to an output pin; an input path from an input pin to
  an audio input converter; either may pass through one mixer or
  selector on the way. SetUpOutputPath and SetUpInputPath look for one,
  power it up, enable the pin and unmute the way through.
}
unit Drivers.HdAudio.Codecs;

{$mode objfpc}
{$pointermath on}

interface

const
  RegisterCapabilities = $00;
  RegisterGlobalControl = $08;
  RegisterStateChange = $0E;
  RegisterInterruptControl = $20;
  RegisterInterruptStatus = $24;

  VerbSetFormat = $2;
  VerbSetAmplifier = $3;
  AmplifierOutput = $8000;
  AmplifierInput = $4000;
  AmplifierBothSides = $3000;
  AmplifierMute = $80;
  RateBit48000 = $40;

type
  { A way through a codec: the converter, the pin, and the mixer or
    selector between them (0 if none). }
  TCodecPath = record
    Codec: LongWord;
    Converter: LongWord;
    Pin: LongWord;
    Between: LongWord;
    { The converter's amplifier steps (its volume or gain), and for an
      input converter the connection it takes (its amplifier's index). }
    AmplifierSteps: LongWord;
    ConnectionIndex: LongWord;
    SupportedRates: LongWord;
  end;

function Read8(Base: PByte; Offset: LongWord): Byte;
procedure Write8(Base: PByte; Offset: LongWord; Value: Byte);
function Read16(Base: PByte; Offset: LongWord): Word;
procedure Write16(Base: PByte; Offset: LongWord; Value: Word);
function Read32(Base: PByte; Offset: LongWord): LongWord;
procedure Write32(Base: PByte; Offset: LongWord; Value: LongWord);

{ A four bit verb with a sixteen bit payload to Node of Codec. }
function ShortVerb(Registers: PByte; Codec, Node, VerbId, Payload: LongWord): LongWord;
{ Looks through every codec present for an output path, or an input
  path, and sets it up with stream tag Tag. }
function FindOutputPath(Registers: PByte; Tag: LongWord; out Path: TCodecPath): Boolean;
function FindInputPath(Registers: PByte; Tag: LongWord; out Path: TCodecPath): Boolean;

implementation

uses
  Runtime.Memory,
  Runtime.Atomic,
  Kernel.Arch.Cpu,
  Kernel.Clock;

const
  RegisterCommandOut = $60;
  RegisterCommandIn = $64;
  RegisterCommandStatus = $68;
  CommandBusy = 1;
  CommandResultValid = 2;
  CommandTimeoutMilliseconds = 100;

  VerbGetParameter = $F00;
  VerbGetConnectionList = $F02;
  VerbGetConfiguration = $F1C;
  VerbSetConnectionSelect = $701;
  VerbSetPowerState = $705;
  VerbSetStream = $706;
  VerbSetPinControl = $707;
  VerbSetExternalAmplifier = $70C;

  ParameterNodeCount = $04;
  ParameterFunctionType = $05;
  ParameterWidgetCapabilities = $09;
  ParameterPcmRates = $0A;
  ParameterPinCapabilities = $0C;
  ParameterInputAmplifier = $0D;
  ParameterConnectionListLength = $0E;
  ParameterOutputAmplifier = $12;

  FunctionTypeAudio = 1;
  WidgetTypeOutput = 0;
  WidgetTypeInput = 1;
  WidgetTypeMixer = 2;
  WidgetTypeSelector = 3;
  WidgetTypePin = 4;
  PinCanOutput = $10;
  PinCanInput = $20;
  PinControlOutput = $40;
  PinControlInput = $20;
  { Configuration default, port connectivity: nothing attached. }
  PortNotConnected = 1;
  MaximumGain = $7F;
  { A node number is eight bits in a verb. }
  MaximumNodeId = $FF;

type
  TPathKind = (PathOutput, PathInput);

{ --- Registers ----------------------------------------------------------------- }

function Read8(Base: PByte; Offset: LongWord): Byte;
begin
  Result := PByte(Base + Offset)^;
  FullMemoryBarrier;
end;

procedure Write8(Base: PByte; Offset: LongWord; Value: Byte);
begin
  FullMemoryBarrier;
  PByte(Base + Offset)^ := Value;
end;

function Read16(Base: PByte; Offset: LongWord): Word;
begin
  Result := PWord(Base + Offset)^;
  FullMemoryBarrier;
end;

procedure Write16(Base: PByte; Offset: LongWord; Value: Word);
begin
  FullMemoryBarrier;
  PWord(Base + Offset)^ := Value;
end;

function Read32(Base: PByte; Offset: LongWord): LongWord;
begin
  Result := PLongWord(Base + Offset)^;
  FullMemoryBarrier;
end;

procedure Write32(Base: PByte; Offset: LongWord; Value: LongWord);
begin
  FullMemoryBarrier;
  PLongWord(Base + Offset)^ := Value;
end;

function WaitFor16(Base: PByte; Offset: LongWord; Mask, Expected: Word): Boolean;
var
  Deadline: QWord;
begin
  Deadline := ClockTickCount + MillisecondsToTicks(CommandTimeoutMilliseconds);
  while (Read16(Base, Offset) and Mask) <> Expected do
  begin
    if ClockTickCount > Deadline then
      Exit(False);
    CpuRelax;
  end;
  Result := True;
end;

{ --- Verbs ------------------------------------------------------------------------ }

{ Sends a command (codec, node, verb and payload) and returns the
  codec's response. }
function SendCommand(Registers: PByte; Command: LongWord; out Response: LongWord): Boolean;
begin
  Response := 0;
  if not WaitFor16(Registers, RegisterCommandStatus, CommandBusy, 0) then
    Exit(False);
  Write16(Registers, RegisterCommandStatus, CommandResultValid);
  Write32(Registers, RegisterCommandOut, Command);
  Write16(Registers, RegisterCommandStatus, CommandBusy);
  Result := WaitFor16(Registers, RegisterCommandStatus, CommandBusy or CommandResultValid, CommandResultValid);
  if Result then
    Response := Read32(Registers, RegisterCommandIn);
end;

{ A twelve bit verb with an eight bit payload. }
function Verb(Registers: PByte; Codec, Node, VerbId, Payload: LongWord): LongWord;
begin
  SendCommand(Registers, (Codec shl 28) or (Node shl 20) or (VerbId shl 8) or (Payload and $FF), Result);
end;

function ShortVerb(Registers: PByte; Codec, Node, VerbId, Payload: LongWord): LongWord;
begin
  SendCommand(Registers, (Codec shl 28) or (Node shl 20) or (VerbId shl 16) or (Payload and $FFFF), Result);
end;

function Parameter(Registers: PByte; Codec, Node, Which: LongWord): LongWord;
begin
  Result := Verb(Registers, Codec, Node, VerbGetParameter, Which);
end;

function WidgetType(Registers: PByte; Codec, Node: LongWord): LongWord;
begin
  Result := (Parameter(Registers, Codec, Node, ParameterWidgetCapabilities) shr 20) and $F;
end;

function ConnectionCount(Registers: PByte; Codec, Node: LongWord): LongWord;
begin
  Result := Parameter(Registers, Codec, Node, ParameterConnectionListLength) and $7F;
end;

{ Entry Index of Node's connection list (short form), 0 if none. }
function Connection(Registers: PByte; Codec, Node, Index: LongWord): LongWord;
var
  Length: LongWord;
begin
  Length := Parameter(Registers, Codec, Node, ParameterConnectionListLength);
  if ((Length and $80) <> 0) or (Index >= (Length and $7F)) then
    Exit(0);
  Result := (Verb(Registers, Codec, Node, VerbGetConnectionList, Index and not 3) shr ((Index and 3) * 8)) and $FF;
end;

{ --- Paths ------------------------------------------------------------------------- }

{ The connection of From that is a widget of type Wanted (and, for a
  pin, one that can take the path's direction), its index in From's
  list returned too; 0 if none. }
function ConnectedWidget(Registers: PByte; Codec, From, Wanted: LongWord; Kind: TPathKind;
  out Index: LongWord): LongWord;
var
  Position: LongWord;
  Candidate: LongWord;
  PinWanted: LongWord;
begin
  Index := 0;
  if Kind = PathOutput then
    PinWanted := PinCanOutput
  else
    PinWanted := PinCanInput;
  Position := 0;
  while Position < ConnectionCount(Registers, Codec, From) do
  begin
    Candidate := Connection(Registers, Codec, From, Position);
    if (Candidate <> 0) and (WidgetType(Registers, Codec, Candidate) = Wanted) and
       ((Wanted <> WidgetTypePin) or
        ((Parameter(Registers, Codec, Candidate, ParameterPinCapabilities) and PinWanted) <> 0)) then
    begin
      Index := Position;
      Exit(Candidate);
    end;
    Inc(Position);
  end;
  Result := 0;
end;

{ The end of a path that starts at Node: for an output path Node is a
  pin and the end a converter; for an input path Node is an input
  converter and the end a pin. Directly, or through one mixer or
  selector (Middle, with the index of the end in its list). Index is
  the position in Node's list of what comes next. }
function FollowPath(Registers: PByte; Codec, Node: LongWord; Kind: TPathKind;
  out Index, Middle, Inner: LongWord): LongWord;
var
  EndType: LongWord;
  Position: LongWord;
begin
  if Kind = PathOutput then
    EndType := WidgetTypeOutput
  else
    EndType := WidgetTypePin;
  Middle := 0;
  Inner := 0;
  Result := ConnectedWidget(Registers, Codec, Node, EndType, Kind, Index);
  if Result <> 0 then
    Exit;
  Position := 0;
  while Position < ConnectionCount(Registers, Codec, Node) do
  begin
    Middle := Connection(Registers, Codec, Node, Position);
    if (Middle <> 0) and (WidgetType(Registers, Codec, Middle) in [WidgetTypeMixer, WidgetTypeSelector]) then
    begin
      Result := ConnectedWidget(Registers, Codec, Middle, EndType, Kind, Inner);
      if Result <> 0 then
      begin
        Index := Position;
        Exit;
      end;
    end;
    Inc(Position);
  end;
  Middle := 0;
  Result := 0;
end;

function PinIsConnected(Registers: PByte; Codec, Pin: LongWord): Boolean;
begin
  Result := (Verb(Registers, Codec, Pin, VerbGetConfiguration, 0) shr 30) <> PortNotConnected;
end;

procedure PowerUp(Registers: PByte; Codec, Node: LongWord);
begin
  Verb(Registers, Codec, Node, VerbSetPowerState, 0);
end;

{ Sets up a path found in Group: unmuted all the way, the converter on
  stream Tag. }
procedure EnablePath(Registers: PByte; Group: LongWord; Kind: TPathKind; Tag: LongWord; Index, Inner: LongWord;
  var Path: TCodecPath);
var
  Codec: LongWord;
begin
  Codec := Path.Codec;
  PowerUp(Registers, Codec, Path.Pin);
  PowerUp(Registers, Codec, Path.Converter);
  if Kind = PathOutput then
  begin
    Verb(Registers, Codec, Path.Pin, VerbSetConnectionSelect, Index);
    Verb(Registers, Codec, Path.Pin, VerbSetPinControl, PinControlOutput);
    Verb(Registers, Codec, Path.Pin, VerbSetExternalAmplifier, 2);
    ShortVerb(Registers, Codec, Path.Pin, VerbSetAmplifier, AmplifierOutput or AmplifierBothSides or MaximumGain);
    Path.AmplifierSteps := (Parameter(Registers, Codec, Path.Converter, ParameterOutputAmplifier) shr 8) and $7F;
  end
  else
  begin
    Verb(Registers, Codec, Path.Converter, VerbSetConnectionSelect, Index);
    Path.ConnectionIndex := Index;
    Verb(Registers, Codec, Path.Pin, VerbSetPinControl, PinControlInput);
    ShortVerb(Registers, Codec, Path.Pin, VerbSetAmplifier, AmplifierInput or AmplifierBothSides or MaximumGain);
    Path.AmplifierSteps := (Parameter(Registers, Codec, Path.Converter, ParameterInputAmplifier) shr 8) and $7F;
  end;
  if Path.Between <> 0 then
  begin
    PowerUp(Registers, Codec, Path.Between);
    Verb(Registers, Codec, Path.Between, VerbSetConnectionSelect, Inner);
    ShortVerb(Registers, Codec, Path.Between, VerbSetAmplifier,
      AmplifierOutput or AmplifierInput or AmplifierBothSides or (Inner shl 8) or MaximumGain);
  end;
  Verb(Registers, Codec, Path.Converter, VerbSetStream, Tag shl 4);
  Path.SupportedRates := Parameter(Registers, Codec, Path.Converter, ParameterPcmRates);
  if Path.SupportedRates = 0 then
    Path.SupportedRates := Parameter(Registers, Codec, Group, ParameterPcmRates);
end;

{ The "subordinate node count" answer (first node in bits 16-23, count
  in bits 0-7) is the codec's: the nodes it names are walked only as far
  as a node number fits a verb (NIDs to 255), and a count of 0 walks
  none (an unsigned "First to First + Count - 1" would run from 0 to
  4 billion). }
function FirstSubordinate(Nodes: LongWord): LongWord;
begin
  Result := (Nodes shr 16) and $FF;
end;

function SubordinateCount(Nodes: LongWord): LongWord;
begin
  Result := Nodes and $FF;
  if FirstSubordinate(Nodes) + Result > MaximumNodeId + 1 then
    Result := MaximumNodeId + 1 - FirstSubordinate(Nodes);
end;

{ Looks in the audio function group Group for a path of Kind. }
function SetUpPath(Registers: PByte; Codec, Group: LongWord; Kind: TPathKind; Tag: LongWord;
  out Path: TCodecPath): Boolean;
var
  Nodes: LongWord;
  Node: LongWord;
  First: LongWord;
  Index: LongWord;
  Middle: LongWord;
  Inner: LongWord;
  Found: LongWord;
  Step: LongWord;
begin
  Result := False;
  ZeroMemory(@Path, SizeOf(Path));
  Path.Codec := Codec;
  Nodes := Parameter(Registers, Codec, Group, ParameterNodeCount);
  First := FirstSubordinate(Nodes);
  PowerUp(Registers, Codec, Group);
  for Step := 1 to SubordinateCount(Nodes) do
  begin
    Node := First + Step - 1;
    if Kind = PathOutput then
    begin
      { From an output pin back to a converter. }
      if (WidgetType(Registers, Codec, Node) <> WidgetTypePin) or
         ((Parameter(Registers, Codec, Node, ParameterPinCapabilities) and PinCanOutput) = 0) or
         not PinIsConnected(Registers, Codec, Node) then
        Continue;
      Found := FollowPath(Registers, Codec, Node, Kind, Index, Middle, Inner);
      if Found = 0 then
        Continue;
      Path.Pin := Node;
      Path.Converter := Found;
    end
    else
    begin
      { From an input converter back to a pin. }
      if WidgetType(Registers, Codec, Node) <> WidgetTypeInput then
        Continue;
      Found := FollowPath(Registers, Codec, Node, Kind, Index, Middle, Inner);
      if (Found = 0) or not PinIsConnected(Registers, Codec, Found) then
        Continue;
      Path.Converter := Node;
      Path.Pin := Found;
    end;
    Path.Between := Middle;
    EnablePath(Registers, Group, Kind, Tag, Index, Inner, Path);
    Exit(True);
  end;
end;

function FindPath(Registers: PByte; Kind: TPathKind; Tag: LongWord; out Path: TCodecPath): Boolean;
var
  Present: Word;
  Codec: LongWord;
  Nodes: LongWord;
  Group: LongWord;
  Step: LongWord;
begin
  Result := False;
  ZeroMemory(@Path, SizeOf(Path));
  Present := Read16(Registers, RegisterStateChange);
  for Codec := 0 to 14 do
  begin
    if (Present and (1 shl Codec)) = 0 then
      Continue;
    Nodes := Parameter(Registers, Codec, 0, ParameterNodeCount);
    for Step := 1 to SubordinateCount(Nodes) do
    begin
      Group := FirstSubordinate(Nodes) + Step - 1;
      if ((Parameter(Registers, Codec, Group, ParameterFunctionType) and $FF) = FunctionTypeAudio) and
         SetUpPath(Registers, Codec, Group, Kind, Tag, Path) then
        Exit(True);
    end;
  end;
end;

function FindOutputPath(Registers: PByte; Tag: LongWord; out Path: TCodecPath): Boolean;
begin
  Result := FindPath(Registers, PathOutput, Tag, Path);
end;

function FindInputPath(Registers: PByte; Tag: LongWord; out Path: TCodecPath): Boolean;
begin
  Result := FindPath(Registers, PathInput, Tag, Path);
end;

end.
