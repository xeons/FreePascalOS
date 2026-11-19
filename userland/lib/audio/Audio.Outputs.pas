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
  The sound outputs as a whole: which there are, what each is, their
  volumes and mutes, and the default one.

  Output N is /dev/audio (N = 0) or /dev/audioN. Each has a volume (the
  hardware's, for everything played on it) and can be muted (it plays
  silence, keeping its volume). One is the default: where programs play
  that name no output (OpenAudioOutput('') in Audio.Device). The kernel
  keeps all of it; anyone may change it, as anyone at the machine could
  turn its knobs. The system settings service remembers what is chosen
  in the system's settings and gives it to the kernel at start.
}
unit Audio.Outputs;

{$mode objfpc}{$H+}

interface

const
  MaximumAudioOutputs = 4;

type
  TAudioOutputState = record
    Volume: LongWord;
    Muted: Boolean;
    { AudioOutputKind*: HD Audio, AC'97, USB, HDMI. }
    Kind: LongWord;
  end;

{ The device file of output Number: /dev/audio, /dev/audio1, ... ('' for
  a number past the last there can be). }
function AudioOutputPath(Number: Integer): string;
{ How many outputs there are (they are numbered without gaps). }
function AudioOutputCount: Integer;
{ What output Number has now; False if there is no such output. }
function DescribeAudioOutput(Number: Integer; out State: TAudioOutputState): Boolean;
{ A name for people: "HD Audio", "AC'97", "USB audio". }
function AudioOutputKindName(Kind: LongWord): string;
{ Each returns ErrorNone or an Abi error (ErrorNotFound: no such
  output). }
function SetAudioOutputVolume(Number: Integer; Volume: LongWord): LongInt;
function SetAudioOutputMuted(Number: Integer; Muted: Boolean): LongInt;
function SetDefaultAudioOutput(Number: Integer): LongInt;
{ The default output's number (0 if it cannot be asked). }
function DefaultAudioOutput: Integer;

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors,
  Sys.Files;

const
  OutputPaths: array[0..MaximumAudioOutputs - 1] of string = (
    '/dev/audio', '/dev/audio1', '/dev/audio2', '/dev/audio3');

function AudioOutputPath(Number: Integer): string;
begin
  if (Number < 0) or (Number >= MaximumAudioOutputs) then
    Exit('');
  Result := OutputPaths[Number];
end;

function OpenOutput(Number: Integer): Int64;
begin
  if AudioOutputPath(Number) = '' then
    Exit(-ErrorNotFound);
  Result := OpenFile(PChar(AudioOutputPath(Number)), OpenWrite);
end;

function AudioOutputCount: Integer;
var
  Handle: Int64;
begin
  Result := 0;
  while Result < MaximumAudioOutputs do
  begin
    Handle := OpenOutput(Result);
    if Handle < 0 then
      Exit;
    CloseFile(Handle);
    Inc(Result);
  end;
end;

function DescribeAudioOutput(Number: Integer; out State: TAudioOutputState): Boolean;
var
  Handle: Int64;
  Answer: Int64;
begin
  State.Volume := 0;
  State.Muted := False;
  State.Kind := 0;
  Handle := OpenOutput(Number);
  if Handle < 0 then
    Exit(False);
  Answer := KernelControlHandle(Handle, ControlAudioGetMasterVolume, 0);
  if Answer >= 0 then
    State.Volume := LongWord(Answer);
  State.Muted := KernelControlHandle(Handle, ControlAudioGetMute, 0) = 1;
  Answer := KernelControlHandle(Handle, ControlAudioGetKind, 0);
  if Answer >= 0 then
    State.Kind := LongWord(Answer);
  CloseFile(Handle);
  Result := True;
end;

function AudioOutputKindName(Kind: LongWord): string;
begin
  case Kind of
    AudioOutputKindHdAudio: Result := 'HD Audio';
    AudioOutputKindAc97: Result := 'AC''97';
    AudioOutputKindUsb: Result := 'USB audio';
    AudioOutputKindHdmi: Result := 'HDMI';
  else
    Result := 'Sound output';
  end;
end;

{ Sends Request with Argument to output Number. }
function ControlOutput(Number: Integer; Request: LongWord; Argument: QWord): LongInt;
var
  Handle: Int64;
begin
  Handle := OpenOutput(Number);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  Result := ErrorCodeOf(KernelControlHandle(Handle, Request, Argument));
  CloseFile(Handle);
end;

function SetAudioOutputVolume(Number: Integer; Volume: LongWord): LongInt;
begin
  Result := ControlOutput(Number, ControlAudioSetMasterVolume, Volume);
end;

function SetAudioOutputMuted(Number: Integer; Muted: Boolean): LongInt;
begin
  Result := ControlOutput(Number, ControlAudioSetMute, Ord(Muted));
end;

function SetDefaultAudioOutput(Number: Integer): LongInt;
begin
  if Number < 0 then
    Exit(ErrorNotFound);
  Result := ControlOutput(0, ControlAudioSetDefaultOutput, QWord(Number));
end;

function DefaultAudioOutput: Integer;
var
  Handle: Int64;
  Answer: Int64;
begin
  Result := 0;
  Handle := OpenOutput(0);
  if Handle < 0 then
    Exit;
  Answer := KernelControlHandle(Handle, ControlAudioGetDefaultOutput, 0);
  if (Answer >= 0) and (Answer < MaximumAudioOutputs) then
    Result := Integer(Answer);
  CloseFile(Handle);
end;

end.
