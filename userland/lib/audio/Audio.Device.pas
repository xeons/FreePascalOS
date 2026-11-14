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
  The audio output device.

  The kernel's audio framework (Io.AudioOutput) gives every sound
  output a device file; the first is /dev/audio. It takes 16-bit
  little-endian samples, mono or stereo, at 44100 or 48000 Hz; writing
  waits while the device's buffer is full, so sound plays at its own
  pace. Draining waits until everything written has been heard; closing
  the device drains it too.
}
unit Audio.Device;

{$mode objfpc}

interface

const
  DefaultAudioDevice: PChar = '/dev/audio';

type
  TAudioFormat = record
    Rate: LongWord;
    Channels: LongWord;
  end;

{ Opens Path (DefaultAudioDevice if nil); returns the handle, or a
  negative error. }
function OpenAudioOutput(Path: PChar): Int64;
procedure CloseAudioOutput(Handle: Int64);
{ 0 or an error code (ErrorInvalidArgument for a format the device does
  not take). }
function SetAudioFormat(Handle: Int64; const Format: TAudioFormat): LongInt;
function GetAudioFormat(Handle: Int64; out Format: TAudioFormat): LongInt;
{ Percent, 0-100. }
function SetAudioVolume(Handle: Int64; Percent: LongWord): LongInt;
function GetAudioVolume(Handle: Int64; out Percent: LongWord): LongInt;
{ Writes all of Buffer (whole samples); 0 or an error code. }
function WriteAudio(Handle: Int64; Buffer: Pointer; ByteCount: QWord): LongInt;
function DrainAudio(Handle: Int64): LongInt;

implementation

uses
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Errors,
  Sys.Files;

const
  BitsPerSample = 16;

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
    (QWord(Format.Rate) shl 16) or (QWord(Format.Channels) shl 8) or BitsPerSample, Answer);
end;

function GetAudioFormat(Handle: Int64; out Format: TAudioFormat): LongInt;
var
  Answer: Int64;
begin
  Result := Control(Handle, ControlAudioGetFormat, 0, Answer);
  Format.Rate := LongWord(Answer shr 16);
  Format.Channels := LongWord((Answer shr 8) and $FF);
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

end.
