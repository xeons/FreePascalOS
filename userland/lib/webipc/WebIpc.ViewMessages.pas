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
  The payloads of the view messages (WebIpc.Messages 100..299) that are
  more than a value or two, as records with an encoder and a decoder
  each; and helpers for the payloads that are a few plain values.
  Decoders raise EIpcMalformed for a payload that does not parse.
}
unit WebIpc.ViewMessages;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  WebIpc.Wire;

const
  { TIpcInputEvent.Kind. }
  InputPointerDown = 1;
  InputPointerMove = 2;
  InputPointerUp = 3;
  InputPointerLeave = 4;
  InputWheel = 5;
  InputKeyDown = 6;
  InputKeyUp = 7;
  InputContextMenu = 8;
  { Text typed through an input method (Text). }
  InputText = 9;
  { The motion of a locked pointer (X, Y: in pixels; Button: the
    buttons held). }
  InputPointerMoveLocked = 10;

  { TIpcDialogRequest.Kind. }
  DialogAlert = 1;
  DialogConfirm = 2;
  DialogPrompt = 3;

type
  TIpcViewGeometry = record
    Width, Height: LongInt;
    ScalePercent, Dpi: LongWord;
  end;

  TIpcViewSetup = record
    Geometry: TIpcViewGeometry;
    Zoom: Double;
    Visible: Boolean;
    Focused: Boolean;
    ScriptingEnabled: Boolean;
  end;

  TIpcInputEvent = record
    Kind: Byte;
    { Each input the browser sends is numbered; the content process says
      how far it got (IpcInputHandled, TIpcFrameInfo). }
    Sequence: LongWord;
    X, Y: LongInt;
    { The button pressed or released, or the buttons held while moving. }
    Button: LongWord;
    Steps: LongInt;
    Code, Character, Modifiers: LongWord;
    FromKeyboard: Boolean;
    Text: string;
  end;

  TIpcSurfaceInfo = record
    SurfaceId: LongWord;
    Width, Height: LongInt;
    StrideBytes: LongInt;
  end;

  TIpcFrameInfo = record
    FrameNumber: LongWord;
    SurfaceId: LongWord;
    Width, Height: LongInt;
    { What changed since the last frame (pixels; all of it after a new
      surface). }
    DamageLeft, DamageTop, DamageRight, DamageBottom: LongInt;
    { The viewport's scroll position and the document's size, in device
      pixels: the browser scrolls the last frame itself while the
      renderer is busy. }
    ScrollX, ScrollY: Double;
    DocumentWidth, DocumentHeight: Double;
    { The part of the surface that is the viewport (without the scroll
      bars), in pixels. }
    ViewportWidth, ViewportHeight: LongInt;
    { Fixed or sticky boxes: the picture cannot simply be moved. }
    HasFixedBoxes: Boolean;
    InputHandled: LongWord;
  end;

  TIpcContextInfo = record
    X, Y: LongInt;
    FromKeyboard: Boolean;
    LinkUrl: string;
    LinkText: string;
    ImageUrl: string;
    SelectedText: string;
    InTextField: Boolean;
    BackgroundImageUrl: string;
    IsEditable: Boolean;
    FrameUrl: string;
    CanCopy: Boolean;
  end;

  TIpcHistoryEntry = record
    Url, Title: string;
  end;

  { A view's session history (IpcHistoryState), or the one to restore
    (IpcRestoreHistory: the flags unused). Index: the current entry (-1
    only when there are none). }
  TIpcHistoryState = record
    CanGoBack, CanGoForward: Boolean;
    Index: LongInt;
    Entries: array of TIpcHistoryEntry;
  end;

  { Find (IpcFind) and the highlight of every match (IpcSetFindHighlight:
    Forward unused). }
  TIpcFindRequest = record
    Needle: string;
    Forward, MatchCase: Boolean;
  end;

  TIpcFindResult = record
    Found: Boolean;
    { The search went past the end (or the start) and went on from the
      other end. }
    Wrapped: Boolean;
    { Matches in the page, -1 unknown. }
    MatchCount: LongInt;
  end;

  TIpcDisplayOptions = record
    ImagesEnabled: Boolean;
    TextOnlyZoom: Boolean;
    AuthorStylesEnabled: Boolean;
    PopupsBlocked: Boolean;
    { An encoding label, '' to detect. }
    EncodingOverride: string;
  end;

  TIpcMetaItem = record
    Name, Content: string;
  end;

  TIpcMediaItem = record
    Url, Kind, AltText: string;
    Width, Height: LongInt;
  end;

  TIpcPageInfo = record
    Url, Title, Referrer, ContentType, Encoding, RenderMode, LastModified: string;
    Meta: array of TIpcMetaItem;
    Media: array of TIpcMediaItem;
    FormCount, LinkCount: LongInt;
  end;

  TIpcMenuItem = record
    Caption: string;
    Shortcut: string;
    Tag: LongInt;
    Enabled: Boolean;
    Checked: Boolean;
    Separator: Boolean;
  end;

  TIpcPopupMenu = record
    MenuId: LongWord;
    { The view's pixels. }
    X, Y: LongInt;
    Items: array of TIpcMenuItem;
  end;

  TIpcOpenUrl = record
    Url: string;
    { TLinkDisposition (WebView.Types). }
    Disposition: Byte;
    Method: string;
    Body: TBytes;
    ContentType: string;
    Replace: Boolean;
    UserInitiated: Boolean;
  end;

  TIpcDialogRequest = record
    Kind: Byte;
    Message: string;
    DefaultText: string;
  end;

  TIpcDialogAnswer = record
    Accepted: Boolean;
    Text: string;
  end;

  TIpcFavicon = record
    Width, Height: LongInt;
    { Width x Height ARGB pixels, row by row. }
    Pixels: array of LongWord;
  end;

function EncodeGeometry(constref Value: TIpcViewGeometry): TBytes;
function DecodeGeometry(const Payload: TBytes): TIpcViewGeometry;
function EncodeViewSetup(constref Value: TIpcViewSetup): TBytes;
function DecodeViewSetup(const Payload: TBytes): TIpcViewSetup;
function EncodeInputEvent(constref Value: TIpcInputEvent): TBytes;
function DecodeInputEvent(const Payload: TBytes): TIpcInputEvent;
function EncodeSurfaceInfo(constref Value: TIpcSurfaceInfo): TBytes;
function DecodeSurfaceInfo(const Payload: TBytes): TIpcSurfaceInfo;
function EncodeFrameInfo(constref Value: TIpcFrameInfo): TBytes;
function DecodeFrameInfo(const Payload: TBytes): TIpcFrameInfo;
function EncodeContextInfo(constref Value: TIpcContextInfo): TBytes;
function DecodeContextInfo(const Payload: TBytes): TIpcContextInfo;
function EncodePopupMenu(constref Value: TIpcPopupMenu): TBytes;
function DecodePopupMenu(const Payload: TBytes): TIpcPopupMenu;
function EncodeOpenUrl(constref Value: TIpcOpenUrl): TBytes;
function DecodeOpenUrl(const Payload: TBytes): TIpcOpenUrl;
function EncodeDialogRequest(constref Value: TIpcDialogRequest): TBytes;
function DecodeDialogRequest(const Payload: TBytes): TIpcDialogRequest;
function EncodeDialogAnswer(constref Value: TIpcDialogAnswer): TBytes;
function DecodeDialogAnswer(const Payload: TBytes): TIpcDialogAnswer;
function EncodeFavicon(constref Value: TIpcFavicon): TBytes;
function DecodeFavicon(const Payload: TBytes): TIpcFavicon;
function EncodeHistoryState(constref Value: TIpcHistoryState): TBytes;
function DecodeHistoryState(const Payload: TBytes): TIpcHistoryState;
function EncodeFindRequest(constref Value: TIpcFindRequest): TBytes;
function DecodeFindRequest(const Payload: TBytes): TIpcFindRequest;
function EncodeFindResult(constref Value: TIpcFindResult): TBytes;
function DecodeFindResult(const Payload: TBytes): TIpcFindResult;
function EncodeDisplayOptions(constref Value: TIpcDisplayOptions): TBytes;
function DecodeDisplayOptions(const Payload: TBytes): TIpcDisplayOptions;
function EncodePageInfo(constref Value: TIpcPageInfo): TBytes;
function DecodePageInfo(const Payload: TBytes): TIpcPageInfo;

{ Payloads of a few plain values. }
function EncodeText(const Text: string): TBytes;
function DecodeText(const Payload: TBytes): string;
function EncodeTexts(const First, Second: string): TBytes;
procedure DecodeTexts(const Payload: TBytes; out First, Second: string);
function EncodeFlag(Value: Boolean): TBytes;
function DecodeFlag(const Payload: TBytes): Boolean;
function EncodeFlags(First, Second: Boolean): TBytes;
procedure DecodeFlags(const Payload: TBytes; out First, Second: Boolean);
function EncodeNumber(Value: LongInt): TBytes;
function DecodeNumber(const Payload: TBytes): LongInt;
function EncodeNumbers(First, Second: LongInt): TBytes;
procedure DecodeNumbers(const Payload: TBytes; out First, Second: LongInt);
function EncodeReal(Value: Double): TBytes;
function DecodeReal(const Payload: TBytes): Double;
function EncodeReals(First, Second: Double): TBytes;
procedure DecodeReals(const Payload: TBytes; out First, Second: Double);

implementation

{ ---- geometry and setup ---- }

procedure WriteGeometry(Writer: TIpcWriter; constref Value: TIpcViewGeometry);
begin
  Writer.WriteLongInt(Value.Width);
  Writer.WriteLongInt(Value.Height);
  Writer.WriteLongWord(Value.ScalePercent);
  Writer.WriteLongWord(Value.Dpi);
end;

procedure ReadGeometry(Reader: TIpcReader; out Value: TIpcViewGeometry);
begin
  Value.Width := Reader.ReadLongInt;
  Value.Height := Reader.ReadLongInt;
  Value.ScalePercent := Reader.ReadLongWord;
  Value.Dpi := Reader.ReadLongWord;
  if (Value.Width < 0) or (Value.Height < 0) or (Value.Width > 16384) or (Value.Height > 16384) or
     (Value.ScalePercent = 0) or (Value.ScalePercent > 1000) then
    raise EIpcMalformed.Create('a view size out of range');
end;

function EncodeGeometry(constref Value: TIpcViewGeometry): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    WriteGeometry(Writer, Value);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeGeometry(const Payload: TBytes): TIpcViewGeometry;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    ReadGeometry(Reader, Result);
  finally
    Reader.Free;
  end;
end;

function EncodeViewSetup(constref Value: TIpcViewSetup): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    WriteGeometry(Writer, Value.Geometry);
    Writer.WriteDouble(Value.Zoom);
    Writer.WriteBoolean(Value.Visible);
    Writer.WriteBoolean(Value.Focused);
    Writer.WriteBoolean(Value.ScriptingEnabled);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeViewSetup(const Payload: TBytes): TIpcViewSetup;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    ReadGeometry(Reader, Result.Geometry);
    Result.Zoom := Reader.ReadDouble;
    Result.Visible := Reader.ReadBoolean;
    Result.Focused := Reader.ReadBoolean;
    Result.ScriptingEnabled := Reader.ReadBoolean;
  finally
    Reader.Free;
  end;
end;

{ ---- input ---- }

function EncodeInputEvent(constref Value: TIpcInputEvent): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteByte(Value.Kind);
    Writer.WriteLongWord(Value.Sequence);
    Writer.WriteLongInt(Value.X);
    Writer.WriteLongInt(Value.Y);
    Writer.WriteLongWord(Value.Button);
    Writer.WriteLongInt(Value.Steps);
    Writer.WriteLongWord(Value.Code);
    Writer.WriteLongWord(Value.Character);
    Writer.WriteLongWord(Value.Modifiers);
    Writer.WriteBoolean(Value.FromKeyboard);
    Writer.WriteString(Value.Text);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeInputEvent(const Payload: TBytes): TIpcInputEvent;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.Kind := Reader.ReadByte;
    Result.Sequence := Reader.ReadLongWord;
    Result.X := Reader.ReadLongInt;
    Result.Y := Reader.ReadLongInt;
    Result.Button := Reader.ReadLongWord;
    Result.Steps := Reader.ReadLongInt;
    Result.Code := Reader.ReadLongWord;
    Result.Character := Reader.ReadLongWord;
    Result.Modifiers := Reader.ReadLongWord;
    Result.FromKeyboard := Reader.ReadBoolean;
    Result.Text := Reader.ReadString;
    if (Result.Kind < InputPointerDown) or (Result.Kind > InputPointerMoveLocked) then
      raise EIpcMalformed.Create('an unknown kind of input');
  finally
    Reader.Free;
  end;
end;

{ ---- surfaces and frames ---- }

function EncodeSurfaceInfo(constref Value: TIpcSurfaceInfo): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteLongWord(Value.SurfaceId);
    Writer.WriteLongInt(Value.Width);
    Writer.WriteLongInt(Value.Height);
    Writer.WriteLongInt(Value.StrideBytes);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeSurfaceInfo(const Payload: TBytes): TIpcSurfaceInfo;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.SurfaceId := Reader.ReadLongWord;
    Result.Width := Reader.ReadLongInt;
    Result.Height := Reader.ReadLongInt;
    Result.StrideBytes := Reader.ReadLongInt;
    if (Result.Width <= 0) or (Result.Height <= 0) or (Result.Width > 16384) or (Result.Height > 16384) or
       (Result.StrideBytes < Result.Width * 4) or (Result.StrideBytes > 65536 * 4) then
      raise EIpcMalformed.Create('a surface size out of range');
  finally
    Reader.Free;
  end;
end;

function EncodeFrameInfo(constref Value: TIpcFrameInfo): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteLongWord(Value.FrameNumber);
    Writer.WriteLongWord(Value.SurfaceId);
    Writer.WriteLongInt(Value.Width);
    Writer.WriteLongInt(Value.Height);
    Writer.WriteLongInt(Value.DamageLeft);
    Writer.WriteLongInt(Value.DamageTop);
    Writer.WriteLongInt(Value.DamageRight);
    Writer.WriteLongInt(Value.DamageBottom);
    Writer.WriteDouble(Value.ScrollX);
    Writer.WriteDouble(Value.ScrollY);
    Writer.WriteDouble(Value.DocumentWidth);
    Writer.WriteDouble(Value.DocumentHeight);
    Writer.WriteLongInt(Value.ViewportWidth);
    Writer.WriteLongInt(Value.ViewportHeight);
    Writer.WriteBoolean(Value.HasFixedBoxes);
    Writer.WriteLongWord(Value.InputHandled);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeFrameInfo(const Payload: TBytes): TIpcFrameInfo;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.FrameNumber := Reader.ReadLongWord;
    Result.SurfaceId := Reader.ReadLongWord;
    Result.Width := Reader.ReadLongInt;
    Result.Height := Reader.ReadLongInt;
    Result.DamageLeft := Reader.ReadLongInt;
    Result.DamageTop := Reader.ReadLongInt;
    Result.DamageRight := Reader.ReadLongInt;
    Result.DamageBottom := Reader.ReadLongInt;
    Result.ScrollX := Reader.ReadDouble;
    Result.ScrollY := Reader.ReadDouble;
    Result.DocumentWidth := Reader.ReadDouble;
    Result.DocumentHeight := Reader.ReadDouble;
    Result.ViewportWidth := Reader.ReadLongInt;
    Result.ViewportHeight := Reader.ReadLongInt;
    Result.HasFixedBoxes := Reader.ReadBoolean;
    Result.InputHandled := Reader.ReadLongWord;
  finally
    Reader.Free;
  end;
end;

{ ---- context menus, pop-up menus ---- }

function EncodeContextInfo(constref Value: TIpcContextInfo): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteLongInt(Value.X);
    Writer.WriteLongInt(Value.Y);
    Writer.WriteBoolean(Value.FromKeyboard);
    Writer.WriteString(Value.LinkUrl);
    Writer.WriteString(Value.LinkText);
    Writer.WriteString(Value.ImageUrl);
    Writer.WriteString(Value.SelectedText);
    Writer.WriteBoolean(Value.InTextField);
    Writer.WriteString(Value.BackgroundImageUrl);
    Writer.WriteBoolean(Value.IsEditable);
    Writer.WriteString(Value.FrameUrl);
    Writer.WriteBoolean(Value.CanCopy);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeContextInfo(const Payload: TBytes): TIpcContextInfo;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.X := Reader.ReadLongInt;
    Result.Y := Reader.ReadLongInt;
    Result.FromKeyboard := Reader.ReadBoolean;
    Result.LinkUrl := Reader.ReadString;
    Result.LinkText := Reader.ReadString;
    Result.ImageUrl := Reader.ReadString;
    Result.SelectedText := Reader.ReadString;
    Result.InTextField := Reader.ReadBoolean;
    Result.BackgroundImageUrl := Reader.ReadString;
    Result.IsEditable := Reader.ReadBoolean;
    Result.FrameUrl := Reader.ReadString;
    Result.CanCopy := Reader.ReadBoolean;
  finally
    Reader.Free;
  end;
end;

function EncodePopupMenu(constref Value: TIpcPopupMenu): TBytes;
var
  Writer: TIpcWriter;
  Index: Integer;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteLongWord(Value.MenuId);
    Writer.WriteLongInt(Value.X);
    Writer.WriteLongInt(Value.Y);
    Writer.WriteLongWord(Length(Value.Items));
    for Index := 0 to High(Value.Items) do
    begin
      Writer.WriteString(Value.Items[Index].Caption);
      Writer.WriteString(Value.Items[Index].Shortcut);
      Writer.WriteLongInt(Value.Items[Index].Tag);
      Writer.WriteBoolean(Value.Items[Index].Enabled);
      Writer.WriteBoolean(Value.Items[Index].Checked);
      Writer.WriteBoolean(Value.Items[Index].Separator);
    end;
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodePopupMenu(const Payload: TBytes): TIpcPopupMenu;
var
  Reader: TIpcReader;
  Count, Index: LongWord;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.MenuId := Reader.ReadLongWord;
    Result.X := Reader.ReadLongInt;
    Result.Y := Reader.ReadLongInt;
    Count := Reader.ReadLongWord;
    { Each item takes at least 15 bytes. }
    if Count > LongWord(Reader.Remaining) div 15 then
      raise EIpcMalformed.Create('a menu longer than its message');
    Result.Items := nil;
    SetLength(Result.Items, Count);
    Index := 0;
    while Index < Count do
    begin
      Result.Items[Index].Caption := Reader.ReadString;
      Result.Items[Index].Shortcut := Reader.ReadString;
      Result.Items[Index].Tag := Reader.ReadLongInt;
      Result.Items[Index].Enabled := Reader.ReadBoolean;
      Result.Items[Index].Checked := Reader.ReadBoolean;
      Result.Items[Index].Separator := Reader.ReadBoolean;
      Inc(Index);
    end;
  finally
    Reader.Free;
  end;
end;

{ ---- navigations to another site ---- }

function EncodeOpenUrl(constref Value: TIpcOpenUrl): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteString(Value.Url);
    Writer.WriteByte(Value.Disposition);
    Writer.WriteString(Value.Method);
    Writer.WriteBytes(Value.Body);
    Writer.WriteString(Value.ContentType);
    Writer.WriteBoolean(Value.Replace);
    Writer.WriteBoolean(Value.UserInitiated);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeOpenUrl(const Payload: TBytes): TIpcOpenUrl;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.Url := Reader.ReadString;
    Result.Disposition := Reader.ReadByte;
    Result.Method := Reader.ReadString;
    Result.Body := Reader.ReadBytes;
    Result.ContentType := Reader.ReadString;
    Result.Replace := Reader.ReadBoolean;
    Result.UserInitiated := Reader.ReadBoolean;
  finally
    Reader.Free;
  end;
end;

{ ---- dialogs ---- }

function EncodeDialogRequest(constref Value: TIpcDialogRequest): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteByte(Value.Kind);
    Writer.WriteString(Value.Message);
    Writer.WriteString(Value.DefaultText);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeDialogRequest(const Payload: TBytes): TIpcDialogRequest;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.Kind := Reader.ReadByte;
    Result.Message := Reader.ReadString;
    Result.DefaultText := Reader.ReadString;
    if (Result.Kind < DialogAlert) or (Result.Kind > DialogPrompt) then
      raise EIpcMalformed.Create('an unknown kind of dialog');
  finally
    Reader.Free;
  end;
end;

function EncodeDialogAnswer(constref Value: TIpcDialogAnswer): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteBoolean(Value.Accepted);
    Writer.WriteString(Value.Text);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeDialogAnswer(const Payload: TBytes): TIpcDialogAnswer;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.Accepted := Reader.ReadBoolean;
    Result.Text := Reader.ReadString;
  finally
    Reader.Free;
  end;
end;

{ ---- the page's icon ---- }

function EncodeFavicon(constref Value: TIpcFavicon): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteLongInt(Value.Width);
    Writer.WriteLongInt(Value.Height);
    if Length(Value.Pixels) > 0 then
      Writer.WriteRaw(@Value.Pixels[0], Length(Value.Pixels) * 4);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeFavicon(const Payload: TBytes): TIpcFavicon;
var
  Reader: TIpcReader;
  Count: Int64;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.Width := Reader.ReadLongInt;
    Result.Height := Reader.ReadLongInt;
    if (Result.Width < 0) or (Result.Height < 0) or (Result.Width > 1024) or (Result.Height > 1024) then
      raise EIpcMalformed.Create('an icon size out of range');
    Count := Int64(Result.Width) * Result.Height;
    if Count * 4 <> Reader.Remaining then
      raise EIpcMalformed.Create('an icon of the wrong length');
    Result.Pixels := nil;
    SetLength(Result.Pixels, Count);
    if Count > 0 then
      Reader.ReadRaw(@Result.Pixels[0], Count * 4);
  finally
    Reader.Free;
  end;
end;

{ ---- session history ---- }

const
  { The most entries a history may have on the wire (libweb keeps 50, a
    browser its cross-site ones besides). }
  HistoryEntryLimit = 1000;
  { The most of each list of Page Info. }
  PageInfoItemLimit = 100000;
  EncodingLabelLimit = 64;

function EncodeHistoryState(constref Value: TIpcHistoryState): TBytes;
var
  Writer: TIpcWriter;
  Index: Integer;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteBoolean(Value.CanGoBack);
    Writer.WriteBoolean(Value.CanGoForward);
    Writer.WriteLongInt(Value.Index);
    Writer.WriteLongWord(Length(Value.Entries));
    for Index := 0 to High(Value.Entries) do
    begin
      Writer.WriteString(Value.Entries[Index].Url);
      Writer.WriteString(Value.Entries[Index].Title);
    end;
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeHistoryState(const Payload: TBytes): TIpcHistoryState;
var
  Reader: TIpcReader;
  Count, Index: LongWord;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.CanGoBack := Reader.ReadBoolean;
    Result.CanGoForward := Reader.ReadBoolean;
    Result.Index := Reader.ReadLongInt;
    Count := Reader.ReadLongWord;
    { Each entry takes at least its two lengths. }
    if (Count > HistoryEntryLimit) or (Count > LongWord(Reader.Remaining) div 8) then
      raise EIpcMalformed.Create('a history longer than its message');
    if (Count = 0) and (Result.Index <> -1) or (Count > 0) and ((Result.Index < 0) or
       (Result.Index >= LongInt(Count))) then
      raise EIpcMalformed.Create('a history''s current entry out of range');
    Result.Entries := nil;
    SetLength(Result.Entries, Count);
    Index := 0;
    while Index < Count do
    begin
      Result.Entries[Index].Url := Reader.ReadString;
      Result.Entries[Index].Title := Reader.ReadString;
      Inc(Index);
    end;
  finally
    Reader.Free;
  end;
end;

{ ---- find ---- }

function EncodeFindRequest(constref Value: TIpcFindRequest): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteString(Value.Needle);
    Writer.WriteBoolean(Value.Forward);
    Writer.WriteBoolean(Value.MatchCase);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeFindRequest(const Payload: TBytes): TIpcFindRequest;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.Needle := Reader.ReadString;
    Result.Forward := Reader.ReadBoolean;
    Result.MatchCase := Reader.ReadBoolean;
  finally
    Reader.Free;
  end;
end;

function EncodeFindResult(constref Value: TIpcFindResult): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteBoolean(Value.Found);
    Writer.WriteBoolean(Value.Wrapped);
    Writer.WriteLongInt(Value.MatchCount);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeFindResult(const Payload: TBytes): TIpcFindResult;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.Found := Reader.ReadBoolean;
    Result.Wrapped := Reader.ReadBoolean;
    Result.MatchCount := Reader.ReadLongInt;
    if Result.MatchCount < -1 then
      raise EIpcMalformed.Create('a negative count of matches');
  finally
    Reader.Free;
  end;
end;

{ ---- display options ---- }

function EncodeDisplayOptions(constref Value: TIpcDisplayOptions): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteBoolean(Value.ImagesEnabled);
    Writer.WriteBoolean(Value.TextOnlyZoom);
    Writer.WriteBoolean(Value.AuthorStylesEnabled);
    Writer.WriteBoolean(Value.PopupsBlocked);
    Writer.WriteString(Value.EncodingOverride);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeDisplayOptions(const Payload: TBytes): TIpcDisplayOptions;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result.ImagesEnabled := Reader.ReadBoolean;
    Result.TextOnlyZoom := Reader.ReadBoolean;
    Result.AuthorStylesEnabled := Reader.ReadBoolean;
    Result.PopupsBlocked := Reader.ReadBoolean;
    Result.EncodingOverride := Reader.ReadString;
    if Length(Result.EncodingOverride) > EncodingLabelLimit then
      raise EIpcMalformed.Create('an encoding label too long to be one');
  finally
    Reader.Free;
  end;
end;

{ ---- Page Info ---- }

function EncodePageInfo(constref Value: TIpcPageInfo): TBytes;
var
  Writer: TIpcWriter;
  Index: Integer;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteStrings([Value.Url, Value.Title, Value.Referrer, Value.ContentType, Value.Encoding, Value.RenderMode,
      Value.LastModified]);
    Writer.WriteLongWord(Length(Value.Meta));
    for Index := 0 to High(Value.Meta) do
    begin
      Writer.WriteString(Value.Meta[Index].Name);
      Writer.WriteString(Value.Meta[Index].Content);
    end;
    Writer.WriteLongWord(Length(Value.Media));
    for Index := 0 to High(Value.Media) do
    begin
      Writer.WriteString(Value.Media[Index].Url);
      Writer.WriteString(Value.Media[Index].Kind);
      Writer.WriteString(Value.Media[Index].AltText);
      Writer.WriteLongInt(Value.Media[Index].Width);
      Writer.WriteLongInt(Value.Media[Index].Height);
    end;
    Writer.WriteLongInt(Value.FormCount);
    Writer.WriteLongInt(Value.LinkCount);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodePageInfo(const Payload: TBytes): TIpcPageInfo;
var
  Reader: TIpcReader;
  Texts: TStringArray;
  Count, Index: LongWord;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Texts := Reader.ReadStrings;
    if Length(Texts) <> 7 then
      raise EIpcMalformed.Create('Page Info without its seven texts');
    Result.Url := Texts[0];
    Result.Title := Texts[1];
    Result.Referrer := Texts[2];
    Result.ContentType := Texts[3];
    Result.Encoding := Texts[4];
    Result.RenderMode := Texts[5];
    Result.LastModified := Texts[6];
    Count := Reader.ReadLongWord;
    { A meta item takes at least its two lengths. }
    if (Count > PageInfoItemLimit) or (Count > LongWord(Reader.Remaining) div 8) then
      raise EIpcMalformed.Create('meta items longer than their message');
    Result.Meta := nil;
    SetLength(Result.Meta, Count);
    Index := 0;
    while Index < Count do
    begin
      Result.Meta[Index].Name := Reader.ReadString;
      Result.Meta[Index].Content := Reader.ReadString;
      Inc(Index);
    end;
    Count := Reader.ReadLongWord;
    { A media item: three lengths and two sizes. }
    if (Count > PageInfoItemLimit) or (Count > LongWord(Reader.Remaining) div 20) then
      raise EIpcMalformed.Create('media items longer than their message');
    Result.Media := nil;
    SetLength(Result.Media, Count);
    Index := 0;
    while Index < Count do
    begin
      Result.Media[Index].Url := Reader.ReadString;
      Result.Media[Index].Kind := Reader.ReadString;
      Result.Media[Index].AltText := Reader.ReadString;
      Result.Media[Index].Width := Reader.ReadLongInt;
      Result.Media[Index].Height := Reader.ReadLongInt;
      Inc(Index);
    end;
    Result.FormCount := Reader.ReadLongInt;
    Result.LinkCount := Reader.ReadLongInt;
    if (Result.FormCount < 0) or (Result.LinkCount < 0) then
      raise EIpcMalformed.Create('a negative count in Page Info');
  finally
    Reader.Free;
  end;
end;

{ ---- plain values ---- }

function EncodeText(const Text: string): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteString(Text);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeText(const Payload: TBytes): string;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result := Reader.ReadString;
  finally
    Reader.Free;
  end;
end;

function EncodeTexts(const First, Second: string): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteString(First);
    Writer.WriteString(Second);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

procedure DecodeTexts(const Payload: TBytes; out First, Second: string);
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    First := Reader.ReadString;
    Second := Reader.ReadString;
  finally
    Reader.Free;
  end;
end;

function EncodeFlag(Value: Boolean): TBytes;
begin
  Result := nil;
  SetLength(Result, 1);
  Result[0] := Ord(Value);
end;

function DecodeFlag(const Payload: TBytes): Boolean;
begin
  if Length(Payload) < 1 then
    raise EIpcMalformed.Create('a flag missing');
  Result := Payload[0] <> 0;
end;

function EncodeFlags(First, Second: Boolean): TBytes;
begin
  Result := nil;
  SetLength(Result, 2);
  Result[0] := Ord(First);
  Result[1] := Ord(Second);
end;

procedure DecodeFlags(const Payload: TBytes; out First, Second: Boolean);
begin
  if Length(Payload) < 2 then
    raise EIpcMalformed.Create('flags missing');
  First := Payload[0] <> 0;
  Second := Payload[1] <> 0;
end;

function EncodeNumber(Value: LongInt): TBytes;
begin
  Result := nil;
  SetLength(Result, 4);
  StoreLongWord(@Result[0], LongWord(Value));
end;

function DecodeNumber(const Payload: TBytes): LongInt;
begin
  if Length(Payload) < 4 then
    raise EIpcMalformed.Create('a number missing');
  Result := LongInt(LoadLongWord(@Payload[0]));
end;

function EncodeNumbers(First, Second: LongInt): TBytes;
begin
  Result := nil;
  SetLength(Result, 8);
  StoreLongWord(@Result[0], LongWord(First));
  StoreLongWord(@Result[4], LongWord(Second));
end;

procedure DecodeNumbers(const Payload: TBytes; out First, Second: LongInt);
begin
  if Length(Payload) < 8 then
    raise EIpcMalformed.Create('numbers missing');
  First := LongInt(LoadLongWord(@Payload[0]));
  Second := LongInt(LoadLongWord(@Payload[4]));
end;

function EncodeReal(Value: Double): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteDouble(Value);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

function DecodeReal(const Payload: TBytes): Double;
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    Result := Reader.ReadDouble;
  finally
    Reader.Free;
  end;
end;

function EncodeReals(First, Second: Double): TBytes;
var
  Writer: TIpcWriter;
begin
  Writer := TIpcWriter.Create;
  try
    Writer.WriteDouble(First);
    Writer.WriteDouble(Second);
    Result := Writer.Data;
  finally
    Writer.Free;
  end;
end;

procedure DecodeReals(const Payload: TBytes; out First, Second: Double);
var
  Reader: TIpcReader;
begin
  Reader := TIpcReader.Create(Payload);
  try
    First := Reader.ReadDouble;
    Second := Reader.ReadDouble;
  finally
    Reader.Free;
  end;
end;

end.
