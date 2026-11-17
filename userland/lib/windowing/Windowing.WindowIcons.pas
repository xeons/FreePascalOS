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
  Window icons: telling the display server what a window's icon is - a
  name of the icon theme, or pictures of a few sizes - and asking it
  what another window's is (the shell's taskbar, a task manager).

  Pictures travel as the clipboard's raw images do (DataFormatBgra, one
  after another in a section); a described icon comes back as one
  picture at the size asked for. TWindow (Windowing.Windows) keeps a
  window's icon and sends it with the calls here.
}
unit Windowing.WindowIcons;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  { A picture of Width x Height pixels ($AARRGGBB, straight alpha), a
    line after another from the top. }
  TIconPicture = record
    Width: LongInt;
    Height: LongInt;
    Pixels: array of LongWord;
  end;
  TIconPictures = array of TIconPicture;

  { What the server says of a window's icon. }
  TDescribedIcon = record
    { WindowIconNamed, WindowIconPictures, or 0 (none). }
    Flags: LongWord;
    { The theme's name, if named. }
    Name: string;
    { Changes whenever the window's icon does. }
    Version: LongWord;
    { At the size asked for; Width 0 if none could be made. }
    Picture: TIconPicture;
  end;

{ Sends the window's icon as a name of the icon theme ('' for none). }
procedure SendWindowIconName(WindowId: LongWord; const Name: string);
{ Sends the window's icon as pictures (none: no icon); False if they
  are too many or too large, or the section cannot be made. }
function SendWindowIconPictures(WindowId: LongWord; const Pictures: TIconPictures): Boolean;
{ Asks the server for window WindowId's icon, its picture PixelSize
  pixels across; False if it did not answer or may not say. }
function DescribeWindowIcon(WindowId: LongWord; PixelSize: LongInt; out Icon: TDescribedIcon): Boolean;
{ The bytes of RequestSetWindowIconPictures for Pictures (each as
  DataFormatBgra); nil if there are too many, or one is empty or too
  large. }
function EncodeIconPictures(const Pictures: TIconPictures): TBytes;

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  Sys.Time,
  Windowing.Protocol,
  Windowing.Connection;

const
  ReplyTimeout = 5000;
  PictureHeaderBytes = 8;

procedure SendWindowIconName(WindowId: LongWord; const Name: string);
var
  Message: TWindowMessage;
begin
  if not IsConnected then
    Exit;
  Message := NewMessage(RequestSetWindowIcon, WindowId);
  if IsValidIconName(Name) then
    SetMessageText(Message, Name);
  SendRequest(Message, -1);
end;

procedure PutLongWord(var Data: TBytes; Offset: LongInt; Value: LongWord);
begin
  Data[Offset] := Byte(Value and $FF);
  Data[Offset + 1] := Byte((Value shr 8) and $FF);
  Data[Offset + 2] := Byte((Value shr 16) and $FF);
  Data[Offset + 3] := Byte((Value shr 24) and $FF);
end;

function PictureIsUsable(const Picture: TIconPicture): Boolean;
begin
  Result := (Picture.Width >= 1) and (Picture.Height >= 1) and (Picture.Width <= MaximumIconSide) and
    (Picture.Height <= MaximumIconSide) and (Length(Picture.Pixels) >= Picture.Width * Picture.Height);
end;

function EncodeIconPictures(const Pictures: TIconPictures): TBytes;
var
  Total: LongInt;
  Offset: LongInt;
  Index: LongInt;
  PixelBytes: LongInt;
begin
  Result := nil;
  if (Length(Pictures) = 0) or (Length(Pictures) > MaximumIconPictures) then
    Exit;
  Total := 0;
  for Index := 0 to High(Pictures) do
  begin
    if not PictureIsUsable(Pictures[Index]) then
      Exit;
    Total := Total + PictureHeaderBytes + Pictures[Index].Width * Pictures[Index].Height * 4;
  end;
  if Total > MaximumIconPictureBytes then
    Exit;
  SetLength(Result, Total);
  Offset := 0;
  for Index := 0 to High(Pictures) do
  begin
    PutLongWord(Result, Offset, LongWord(Pictures[Index].Width));
    PutLongWord(Result, Offset + 4, LongWord(Pictures[Index].Height));
    Offset := Offset + PictureHeaderBytes;
    PixelBytes := Pictures[Index].Width * Pictures[Index].Height * 4;
    { $AARRGGBB in memory is blue, green, red, alpha (little endian). }
    Move(Pictures[Index].Pixels[0], Result[Offset], PixelBytes);
    Offset := Offset + PixelBytes;
  end;
end;

function SendWindowIconPictures(WindowId: LongWord; const Pictures: TIconPictures): Boolean;
var
  Message: TWindowMessage;
  Data: TBytes;
  Section: Int64;
  Bytes: Pointer;
begin
  Result := False;
  if not IsConnected then
    Exit;
  Message := NewMessage(RequestSetWindowIconPictures, WindowId);
  if Length(Pictures) = 0 then
  begin
    SendRequest(Message, -1);
    Exit(True);
  end;
  Data := EncodeIconPictures(Pictures);
  if Length(Data) = 0 then
    Exit;
  Section := CreateSection(Length(Data));
  if Section < 0 then
    Exit;
  Bytes := MapSection(Section, 0, Length(Data));
  if Bytes = nil then
  begin
    CloseHandle(Section);
    Exit;
  end;
  Move(Data[0], Bytes^, Length(Data));
  UnmapSection(Bytes);
  Message.Code := Length(Pictures);
  Message.Width := Length(Data);
  { The server takes a reference of its own. }
  SendRequest(Message, Section);
  CloseHandle(Section);
  Result := True;
end;

{ Reads the described picture out of Section (closing it). }
procedure ReadDescribedPicture(Section: Int64; Width, Height: LongInt; var Picture: TIconPicture);
var
  Bytes: Pointer;
begin
  Picture.Width := 0;
  Picture.Height := 0;
  Picture.Pixels := nil;
  if Section < 0 then
    Exit;
  if (Width >= 1) and (Height >= 1) and (Width <= MaximumIconSide) and (Height <= MaximumIconSide) then
  begin
    Bytes := MapSection(Section, 0, QWord(Width) * QWord(Height) * 4);
    if Bytes <> nil then
    begin
      Picture.Width := Width;
      Picture.Height := Height;
      SetLength(Picture.Pixels, Width * Height);
      Move(Bytes^, Picture.Pixels[0], Width * Height * 4);
      UnmapSection(Bytes);
    end;
  end;
  CloseHandle(Section);
end;

procedure DropHandle(Handle: Int64);
begin
  if Handle >= 0 then
    CloseHandle(Handle);
end;

function DescribeWindowIcon(WindowId: LongWord; PixelSize: LongInt; out Icon: TDescribedIcon): Boolean;
var
  Message: TWindowMessage;
  Section: Int64;
  Deadline: QWord;
  Now: QWord;
begin
  Icon.Flags := 0;
  Icon.Name := '';
  Icon.Version := 0;
  Icon.Picture.Width := 0;
  Icon.Picture.Height := 0;
  Icon.Picture.Pixels := nil;
  Result := False;
  if not IsConnected then
    Exit;
  Message := NewMessage(RequestDescribeWindowIcon, WindowId);
  Message.Code := LongWord(PixelSize);
  SendRequest(Message, -1);
  Deadline := UptimeMilliseconds + ReplyTimeout;
  repeat
    Now := UptimeMilliseconds;
    if Now >= Deadline then
      Exit;
    if not WaitForEvent(EventWindowIconDescribed, Deadline - Now, Message) then
      Exit;
    Section := TakeMessageHandle(Message);
    if Message.Window = 0 then
    begin
      DropHandle(Section);
      Exit;
    end;
    { An answer about another window came too late for an earlier
      question. }
    if Message.Window <> WindowId then
    begin
      DropHandle(Section);
      Continue;
    end;
    Icon.Flags := Message.Flags;
    Icon.Name := MessageText(Message);
    Icon.Version := LongWord(Message.Value);
    ReadDescribedPicture(Section, Message.Width, Message.Height, Icon.Picture);
    Exit(True);
  until False;
end;

end.
