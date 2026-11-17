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
  Window icons: what each window's program said its icon is, and the
  icon's picture at the size a title bar (or a program asking) wants.

  An icon is a name of the icon theme (RequestSetWindowIcon), whose
  file /usr/share/icons/NAME.ico is read once and each size made once
  (Controls.IconFiles: that entry, else the nearest larger shrunk, else
  the largest grown), or pictures the program gave
  (RequestSetWindowIconPictures), kept with the window, of which the
  nearest size is used the same way. A window with neither shows its
  owner's (a dialog shows its main window's), else that of its
  program's first window owned by none that has one. Each change gives the
  window a new version, which the shell and the window list hear
  (Server.Shell, Server.WindowList); a program asks for an icon's
  picture with RequestDescribeWindowIcon and gets it in a section.
}
unit Server.WindowIcons;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Image.Model,
  Windowing.Protocol,
  Server.Clients,
  Server.Windows;

type
  { The pictures a program gave for its window, and the sizes made of
    them. }
  TWindowIconPictures = class
  private
    FPictures: array of TImage;
    FSized: array of TImage;
    function NearestPicture(PixelSize: LongInt): TImage;
  public
    destructor Destroy; override;
    { Takes Picture as its own. }
    procedure Add(Picture: TImage);
    function Count: LongInt;
    { The picture at PixelSize x PixelSize (kept here); nil if none. }
    function PictureAt(PixelSize: LongInt): TImage;
  end;

{ Carries out the icon requests (closing Handle); False if Message is
  not one. }
function CarryOutIconRequest(Client: TClient; var Message: TWindowMessage; Handle: Int64): Boolean;
{ The window whose icon Window shows: itself if it has one, else the
  nearest owner with one, else the first window of its program owned by
  none that has one (a dialog made without an owner); nil if none has. }
function IconSourceOf(Window: TServerWindow): TServerWindow;
{ The version of the icon Window shows (0: none), which the shell and
  the window list hear. }
function ShownIconVersion(Window: TServerWindow): LongWord;
{ The icon Window shows, PixelSize pixels across (kept here: not to be
  freed); nil if it has none (or its name has no file). }
function WindowIconPicture(Window: TServerWindow; PixelSize: LongInt): TImage;
{ Parses RequestSetWindowIconPictures' bytes into Pictures (Count of
  them); False if they are not that. }
function ParseIconPictures(const Data: TBytes; Count: LongInt; Pictures: TWindowIconPictures): Boolean;

implementation

uses
  Abi.SystemCalls,
  Sys.Objects,
  Image.Resampling,
  Controls.IconFiles,
  Server.Composer,
  Server.WindowList;

const
  PictureHeaderBytes = 8;

var
  { The last version given; every change takes the next. }
  LastIconVersion: LongWord;

{ --- TWindowIconPictures ----------------------------------------------------- }

destructor TWindowIconPictures.Destroy;
var
  Index: LongInt;
begin
  for Index := 0 to High(FPictures) do
    FPictures[Index].Free;
  for Index := 0 to High(FSized) do
    FSized[Index].Free;
  inherited Destroy;
end;

procedure TWindowIconPictures.Add(Picture: TImage);
begin
  Insert(Picture, FPictures, Length(FPictures));
end;

function TWindowIconPictures.Count: LongInt;
begin
  Result := Length(FPictures);
end;

{ That size, else the smallest larger, else the largest. }
function TWindowIconPictures.NearestPicture(PixelSize: LongInt): TImage;
var
  Index: LongInt;
  Side: LongInt;
  LargerSide: LongInt;
  LargestSide: LongInt;
  Larger: TImage;
  Largest: TImage;
begin
  Larger := nil;
  Largest := nil;
  LargerSide := 0;
  LargestSide := 0;
  for Index := 0 to High(FPictures) do
  begin
    if (FPictures[Index].Width = PixelSize) and (FPictures[Index].Height = PixelSize) then
      Exit(FPictures[Index]);
    Side := FPictures[Index].Width;
    if FPictures[Index].Height > Side then
      Side := FPictures[Index].Height;
    if (Side >= PixelSize) and ((Larger = nil) or (Side < LargerSide)) then
    begin
      Larger := FPictures[Index];
      LargerSide := Side;
    end;
    if (Largest = nil) or (Side > LargestSide) then
    begin
      Largest := FPictures[Index];
      LargestSide := Side;
    end;
  end;
  if Larger <> nil then
    Result := Larger
  else
    Result := Largest;
end;

function TWindowIconPictures.PictureAt(PixelSize: LongInt): TImage;
var
  Index: LongInt;
  Source: TImage;
begin
  Result := nil;
  if (PixelSize < 1) or (PixelSize > MaximumIconSide) then
    Exit;
  Source := NearestPicture(PixelSize);
  if Source = nil then
    Exit;
  if (Source.Width = PixelSize) and (Source.Height = PixelSize) then
    Exit(Source);
  for Index := 0 to High(FSized) do
    if (FSized[Index].Width = PixelSize) and (FSized[Index].Height = PixelSize) then
      Exit(FSized[Index]);
  Result := ResampleImage(Source, PixelSize, PixelSize, ResamplingMitchell);
  Insert(Result, FSized, Length(FSized));
end;

{ --- Parsing ------------------------------------------------------------------ }

function GetLongWord(const Data: TBytes; Offset: LongInt): LongWord;
begin
  Result := LongWord(Data[Offset]) or (LongWord(Data[Offset + 1]) shl 8) or (LongWord(Data[Offset + 2]) shl 16) or
    (LongWord(Data[Offset + 3]) shl 24);
end;

function ParseIconPictures(const Data: TBytes; Count: LongInt; Pictures: TWindowIconPictures): Boolean;
var
  Offset: LongInt;
  Number: LongInt;
  Width: LongWord;
  Height: LongWord;
  PixelBytes: LongInt;
  Picture: TImage;
begin
  Result := False;
  if (Count < 1) or (Count > MaximumIconPictures) or (Length(Data) > MaximumIconPictureBytes) then
    Exit;
  Offset := 0;
  for Number := 1 to Count do
  begin
    if Offset + PictureHeaderBytes > Length(Data) then
      Exit;
    Width := GetLongWord(Data, Offset);
    Height := GetLongWord(Data, Offset + 4);
    if (Width < 1) or (Height < 1) or (Width > MaximumIconSide) or (Height > MaximumIconSide) then
      Exit;
    Offset := Offset + PictureHeaderBytes;
    PixelBytes := LongInt(Width * Height * 4);
    if Offset + PixelBytes > Length(Data) then
      Exit;
    Picture := TImage.Create(LongInt(Width), LongInt(Height));
    Move(Data[Offset], Picture.Line(0)^, PixelBytes);
    Pictures.Add(Picture);
    Offset := Offset + PixelBytes;
  end;
  Result := True;
end;

{ --- The windows' icons ---------------------------------------------------------- }

function HasIcon(Window: TServerWindow): Boolean;
begin
  Result := (Window.IconName <> '') or (Window.IconPictures <> nil);
end;

{ The first window of the same program, owned by none, with an icon:
  what a window of that program with none of its own shows. }
function ProgramIconWindow(Window: TServerWindow): TServerWindow;
var
  Index: LongInt;
begin
  for Index := 0 to WindowCount - 1 do
    if (Windows[Index].Client = Window.Client) and (Windows[Index].OwnerWindow = nil) and HasIcon(Windows[Index]) then
      Exit(Windows[Index]);
  Result := nil;
end;

function IconSourceOf(Window: TServerWindow): TServerWindow;
begin
  Result := Window;
  while Result <> nil do
  begin
    if HasIcon(Result) then
      Exit;
    Result := Result.OwnerWindow;
  end;
  if Window <> nil then
    Result := ProgramIconWindow(Window);
end;

function ShownIconVersion(Window: TServerWindow): LongWord;
var
  Source: TServerWindow;
begin
  Source := IconSourceOf(Window);
  if Source = nil then
    Result := 0
  else
    Result := Source.IconVersion;
end;

function WindowIconPicture(Window: TServerWindow; PixelSize: LongInt): TImage;
var
  Source: TServerWindow;
begin
  Result := nil;
  if PixelSize < 1 then
    Exit;
  Source := IconSourceOf(Window);
  if Source = nil then
    Exit;
  if Source.IconPictures <> nil then
    Result := TWindowIconPictures(Source.IconPictures).PictureAt(PixelSize)
  else
    Result := IconPicture(Source.IconName, PixelSize);
end;

{ The window and every window showing its icon are drawn again. }
procedure IconChanged(Window: TServerWindow);
var
  Index: LongInt;
begin
  Inc(LastIconVersion);
  Window.IconVersion := LastIconVersion;
  for Index := 0 to WindowCount - 1 do
    if Windows[Index].Visible and IsFramed(Windows[Index]) and (IconSourceOf(Windows[Index]) = Window) then
      DamageWindow(Windows[Index]);
  if Window.Visible and IsFramed(Window) then
    DamageWindow(Window);
end;

procedure ClearIcon(Window: TServerWindow);
begin
  Window.IconName := '';
  FreeAndNil(Window.IconPictures);
end;

procedure SetIconName(Window: TServerWindow; const Name: string);
begin
  ClearIcon(Window);
  if IsValidIconName(Name) then
    Window.IconName := Name;
  IconChanged(Window);
end;

{ The bytes a program gave in Section (closed here). }
function ReadIconSection(Section: Int64; Length: LongInt; out Data: TBytes): Boolean;
var
  Bytes: Pointer;
begin
  Data := nil;
  Result := False;
  if Section < 0 then
    Exit;
  if (Length > 0) and (Length <= MaximumIconPictureBytes) then
  begin
    Bytes := MapSection(Section, 0, QWord(Length));
    if Bytes <> nil then
    begin
      SetLength(Data, Length);
      Move(Bytes^, Data[0], Length);
      UnmapSection(Bytes);
      Result := True;
    end;
  end;
  CloseHandle(Section);
end;

procedure SetIconPictures(Window: TServerWindow; const Message: TWindowMessage; Handle: Int64);
var
  Data: TBytes;
  Pictures: TWindowIconPictures;
begin
  if Message.Code = 0 then
  begin
    if Handle >= 0 then
      CloseHandle(Handle);
    ClearIcon(Window);
    IconChanged(Window);
    Exit;
  end;
  if not ReadIconSection(Handle, Message.Width, Data) then
    Exit;
  Pictures := TWindowIconPictures.Create;
  if not ParseIconPictures(Data, LongInt(Message.Code), Pictures) then
  begin
    Pictures.Free;
    Exit;
  end;
  ClearIcon(Window);
  Window.IconPictures := Pictures;
  IconChanged(Window);
end;

procedure SendNoIcon(Client: TClient);
var
  Reply: TWindowMessage;
begin
  Reply := NewMessage(EventWindowIconDescribed, 0);
  SendToClient(Client, Reply);
end;

{ Sends Client the icon Window shows, its picture PixelSize across. }
procedure DescribeIcon(Client: TClient; Window: TServerWindow; PixelSize: LongInt);
var
  Reply: TWindowMessage;
  Source: TServerWindow;
  Picture: TImage;
  Section: Int64;
  Bytes: Pointer;
  ByteCount: QWord;
begin
  Reply := NewMessage(EventWindowIconDescribed, Window.Id);
  Source := IconSourceOf(Window);
  if Source = nil then
  begin
    SendToClient(Client, Reply);
    Exit;
  end;
  Reply.Value := LongInt(Source.IconVersion);
  if Source.IconPictures <> nil then
    Reply.Flags := WindowIconPictures
  else
  begin
    Reply.Flags := WindowIconNamed;
    SetMessageText(Reply, Source.IconName);
  end;
  Picture := nil;
  if (PixelSize >= 1) and (PixelSize <= MaximumIconSide) then
    Picture := WindowIconPicture(Window, PixelSize);
  if Picture = nil then
  begin
    SendToClient(Client, Reply);
    Exit;
  end;
  ByteCount := QWord(Picture.Width) * QWord(Picture.Height) * 4;
  Section := CreateSection(ByteCount);
  if Section < 0 then
  begin
    SendToClient(Client, Reply);
    Exit;
  end;
  Bytes := MapSection(Section, 0, ByteCount);
  if Bytes = nil then
  begin
    CloseHandle(Section);
    SendToClient(Client, Reply);
    Exit;
  end;
  Move(Picture.Line(0)^, Bytes^, ByteCount);
  UnmapSection(Bytes);
  Reply.Width := Picture.Width;
  Reply.Height := Picture.Height;
  SendMessage(Client.Channel, @Reply, SizeOf(Reply), [Section]);
  CloseHandle(Section);
end;

function IsIconRequest(Kind: LongWord): Boolean;
begin
  Result := (Kind = RequestSetWindowIcon) or (Kind = RequestSetWindowIconPictures) or
    (Kind = RequestDescribeWindowIcon);
end;

function CarryOutIconRequest(Client: TClient; var Message: TWindowMessage; Handle: Int64): Boolean;
var
  Window: TServerWindow;
begin
  Result := IsIconRequest(Message.Kind);
  if not Result then
    Exit;
  Window := FindWindow(Message.Window);
  if Message.Kind = RequestDescribeWindowIcon then
  begin
    if Handle >= 0 then
      CloseHandle(Handle);
    if (Window = nil) or not MayListWindow(Client, Window) then
      SendNoIcon(Client)
    else
      DescribeIcon(Client, Window, LongInt(Message.Code));
    Exit;
  end;
  { Only a program's own windows take an icon from it. }
  if (Window = nil) or (Window.Client <> Client) then
  begin
    if Handle >= 0 then
      CloseHandle(Handle);
    Exit;
  end;
  if Message.Kind = RequestSetWindowIcon then
  begin
    if Handle >= 0 then
      CloseHandle(Handle);
    SetIconName(Window, MessageText(Message));
  end
  else
    SetIconPictures(Window, Message, Handle);
end;

end.
