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
  The audio devices: outputs and inputs.

  The kernel's audio framework (Io.AudioOutput) gives every sound
  output a device file; the first is /dev/audio. Each open is a stream
  of its own, mixed with what other programs play: its format is any
  sample kind of Audio.Formats, 1 to 8 channels and 8000 to 192000 Hz
  (the kernel converts). Writing waits while the stream's queue is full,
  so sound plays at its own pace. Draining waits until everything
  written has been heard; closing the device drains it too. A stream
  has its own volume; the master volume is the output's, for all.

  Inputs (Io.AudioInput) work the same way the other way round: the
  first is /dev/audioin, and each output has a monitor input
  (/dev/audiomonitor for /dev/audio) that records what it plays. Each
  open is a capture stream of its own format; reading waits until there
  is something to read. A stream has its own volume; the master volume
  is the input's gain.
}
unit Audio.Device;

{$mode objfpc}

interface

const
  DefaultAudioDevice: PChar = '/dev/audio';
  DefaultAudioInput: PChar = '/dev/audioin';

type
  TAudioFormat = record
    Rate: LongWord;
    Channels: LongWord;
    { One of the Sample* kinds of Audio.Formats. }
    Kind: LongWord;
  end;

{ Opens Path (DefaultAudioDevice if nil); returns the handle, or a
  negative error. }
function OpenAudioOutput(Path: PChar): Int64;
procedure CloseAudioOutput(Handle: Int64);
{ 0 or an error code (ErrorInvalidArgument for a format the device does
  not take). }
function SetAudioFormat(Handle: Int64; const Format: TAudioFormat): LongInt;
function GetAudioFormat(Handle: Int64; out Format: TAudioFormat): LongInt;
{ The stream's volume, percent (0-100). }
function SetAudioVolume(Handle: Int64; Percent: LongWord): LongInt;
function GetAudioVolume(Handle: Int64; out Percent: LongWord): LongInt;
{ The output's volume, percent. }
function SetMasterVolume(Handle: Int64; Percent: LongWord): LongInt;
function GetMasterVolume(Handle: Int64; out Percent: LongWord): LongInt;
{ Bytes written and not yet mixed. }
function QueuedAudioBytes(Handle: Int64): Int64;
{ Writes all of Buffer (whole samples); 0 or an error code. }
function WriteAudio(Handle: Int64; Buffer: Pointer; ByteCount: QWord): LongInt;
function DrainAudio(Handle: Int64): LongInt;

{ Opens the input Path (DefaultAudioInput if nil); returns the handle,
  or a negative error. The format, volumes and queue calls above work on
  it too. }
function OpenAudioInput(Path: PChar): Int64;
{ Reads up to ByteCount bytes (whole frames), waiting for at least one
  frame; returns how many, or a negative error. }
function ReadAudio(Handle: Int64; Buffer: Pointer; ByteCount: QWord): Int64;
{ Frames the input dropped because they were not read in time. }
function DroppedAudioFrames(Handle: Int64): Int64;

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors,
  Sys.Files;

function OpenAudioOutput(Path: PChar): Int64;
begin
  if Path = nil then
    Path := DefaultAudioDevice;
  Result := OpenFile(Path, OpenWrite);
end;

procedure CloseAudioOutput(Handle: Int64);
begin
  CloseFile(Handle);
end;

function Control(Handle: Int64; Request: LongWord; Argument: QWord; out Answer: Int64): LongInt;
begin
  Answer := KernelControlHandle(Handle, Request, Argument);
  if Answer < 0 then
    Result := ErrorCodeOf(Answer)
  else
    Result := ErrorNone;
end;

function SetAudioFormat(Handle: Int64; const Format: TAudioFormat): LongInt;
var
  Answer: Int64;
begin
  Result := Control(Handle, ControlAudioSetFormat,
    (QWord(Format.Rate) shl 16) or (QWord(Format.Channels) shl 8) or Format.Kind, Answer);
end;

function GetAudioFormat(Handle: Int64; out Format: TAudioFormat): LongInt;
var
  Answer: Int64;
begin
  Result := Control(Handle, ControlAudioGetFormat, 0, Answer);
  Format.Rate := LongWord(Answer shr 16);
  Format.Channels := LongWord((Answer shr 8) and $FF);
  Format.Kind := LongWord(Answer and $FF);
end;

function SetAudioVolume(Handle: Int64; Percent: LongWord): LongInt;
var
  Answer: Int64;
begin
  Result := Control(Handle, ControlAudioSetVolume, Percent, Answer);
end;

function GetAudioVolume(Handle: Int64; out Percent: LongWord): LongInt;
var
  Answer: Int64;
begin
  Result := Control(Handle, ControlAudioGetVolume, 0, Answer);
  Percent := LongWord(Answer);
end;

function SetMasterVolume(Handle: Int64; Percent: LongWord): LongInt;
var
  Answer: Int64;
begin
  Result := Control(Handle, ControlAudioSetMasterVolume, Percent, Answer);
end;

function GetMasterVolume(Handle: Int64; out Percent: LongWord): LongInt;
var
  Answer: Int64;
begin
  Result := Control(Handle, ControlAudioGetMasterVolume, 0, Answer);
  Percent := LongWord(Answer);
end;

function QueuedAudioBytes(Handle: Int64): Int64;
begin
  Result := KernelControlHandle(Handle, ControlAudioGetQueued, 0);
end;

function WriteAudio(Handle: Int64; Buffer: Pointer; ByteCount: QWord): LongInt;
begin
  Result := WriteAll(Handle, Buffer, ByteCount);
end;

function DrainAudio(Handle: Int64): LongInt;
var
  Answer: Int64;
begin
  Result := Control(Handle, ControlAudioDrain, 0, Answer);
end;

function OpenAudioInput(Path: PChar): Int64;
begin
  if Path = nil then
    Path := DefaultAudioInput;
  Result := OpenFile(Path, OpenRead);
end;

function ReadAudio(Handle: Int64; Buffer: Pointer; ByteCount: QWord): Int64;
begin
  Result := ReadFile(Handle, Buffer, ByteCount);
end;

function DroppedAudioFrames(Handle: Int64): Int64;
begin
  Result := KernelControlHandle(Handle, ControlAudioGetDropped, 0);
end;

end.
