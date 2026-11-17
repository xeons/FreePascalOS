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
  Image lists: pictures of one logical size (16 x 16, say) that list
  views, tree views, toolbars, tab controls and menus share, each item
  of those naming one by its index (ImageIndex).

  A picture may come in several pixel sizes (16, 24 and 32 pixels for
  100, 150 and 200 % displays): added one by one (Add, then AddVariant),
  from an icon file (every size it has, the deepest of each: AddIcon,
  AddFromFile), or from a strip of pictures side by side (AddStrip,
  AddStripVariants). Drawn, a picture is shown at its logical size at
  the display's scale (Draw), or fitted into a box (DrawInBox): from
  the pixel size that serves it best (Controls.ImageSizes: the exact
  size, else the nearest larger, else the largest), resampled smoothly
  when none is exact. Disabled, it is greyed; selected, tinted with the
  selection's colour (Controls.ImageEffects). Whatever is made for a
  size and a look is kept, so drawing again costs only the copy.

  The list keeps its own copies of what it is given. A control does not
  own the list it shows: the list must last as long as they do.
}
unit Controls.ImageList;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Drawing.Rectangles,
  Drawing.Canvas,
  Image.Model,
  Controls.ImageSizes;

type
  TImageDrawState = (ImageDrawNormal, ImageDrawDisabled, ImageDrawSelected);

  { A picture made for a size and a look. }
  TPreparedImage = record
    Width: LongInt;
    Height: LongInt;
    State: TImageDrawState;
    Image: TImage;
  end;

  TImageListEntry = class
  private
    FVariants: array of TImage;
    FPrepared: array of TPreparedImage;
  public
    destructor Destroy; override;
    procedure AddVariant(Image: TImage);
    procedure ForgetPrepared;
  end;

  TImageList = class
  private
    FWidth: LongInt;
    FHeight: LongInt;
    FEntries: array of TImageListEntry;
    function GetCount: LongInt;
    function Entry(Index: LongInt): TImageListEntry;
    function NewEntry: LongInt;
    function StripFrameWidth(Strip: TImage): LongInt;
    function PrepareImage(Item: TImageListEntry; Width, Height: LongInt; State: TImageDrawState): TImage;
  public
    { Pictures of LogicalWidth x LogicalHeight (logical units). }
    constructor Create(LogicalWidth, LogicalHeight: LongInt);
    destructor Destroy; override;
    { A new picture, from a copy of Image; its index. }
    function Add(Image: TImage): LongInt;
    { Another pixel size of picture Index (a copy of Image). }
    procedure AddVariant(Index: LongInt; Image: TImage);
    { A new picture with every size in an icon file's data (the
      deepest picture of each); -1 if it has none that can be read. }
    function AddIcon(const Data: TBytes): LongInt;
    { A new picture from a file: an icon file's sizes, or any image
      file libimage reads; -1 if it cannot be read. }
    function AddFromFile(const FileName: string): LongInt;
    { New pictures from a strip of them side by side, each as tall as
      the strip and as wide as the list's proportions make it; the
      first one's index (-1 if the strip holds none). }
    function AddStrip(Strip: TImage): LongInt;
    { Another pixel size of the pictures from FirstIndex on, from a
      strip like AddStrip's. }
    procedure AddStripVariants(FirstIndex: LongInt; Strip: TImage);
    procedure Clear;
    function VariantCount(Index: LongInt): LongInt;
    function Variant(Index, VariantIndex: LongInt): TImage;
    { Picture Index at Width x Height pixels with that look (the list's
      own, kept until the list changes); nil for an index it has not. }
    function PreparedImage(Index, Width, Height: LongInt; State: TImageDrawState = ImageDrawNormal): TImage;
    { Draws picture Index with its top left at (X, Y), at its logical
      size at the display's scale. }
    procedure Draw(const Canvas: TCanvas; Index, X, Y: LongInt; State: TImageDrawState = ImageDrawNormal);
    { Draws picture Index as large as fits in Box (proportions kept),
      centred in it. }
    procedure DrawInBox(const Canvas: TCanvas; Index: LongInt; const Box: TRectangle;
      State: TImageDrawState = ImageDrawNormal);
    function ValidIndex(Index: LongInt): Boolean;
    property Count: LongInt read GetCount;
    { The logical size. }
    property Width: LongInt read FWidth;
    property Height: LongInt read FHeight;
  end;

implementation

uses
  Drawing.Colors,
  Windowing.Theme,
  Windowing.Connection,
  Image.Errors,
  Image.Files,
  Image.Surfaces,
  Image.Resampling,
  Image.Ico.Directory,
  Image.Ico.Reading,
  Controls.ImageEffects;

const
  { How much of the selection's colour a selected picture takes (of 255). }
  SelectedTintWeight = 96;

{ --- TImageListEntry ------------------------------------------------------ }

destructor TImageListEntry.Destroy;
var
  Index: LongInt;
begin
  ForgetPrepared;
  for Index := 0 to High(FVariants) do
    FVariants[Index].Free;
  inherited Destroy;
end;

procedure TImageListEntry.AddVariant(Image: TImage);
begin
  SetLength(FVariants, Length(FVariants) + 1);
  FVariants[High(FVariants)] := Image;
  ForgetPrepared;
end;

procedure TImageListEntry.ForgetPrepared;
var
  Index: LongInt;
begin
  for Index := 0 to High(FPrepared) do
    FPrepared[Index].Image.Free;
  FPrepared := nil;
end;

{ --- TImageList ----------------------------------------------------------- }

constructor TImageList.Create(LogicalWidth, LogicalHeight: LongInt);
begin
  inherited Create;
  FWidth := LogicalWidth;
  FHeight := LogicalHeight;
end;

destructor TImageList.Destroy;
begin
  Clear;
  inherited Destroy;
end;

function TImageList.GetCount: LongInt;
begin
  Result := Length(FEntries);
end;

function TImageList.ValidIndex(Index: LongInt): Boolean;
begin
  Result := (Index >= 0) and (Index < Length(FEntries));
end;

function TImageList.Entry(Index: LongInt): TImageListEntry;
begin
  if not ValidIndex(Index) then
    Exit(nil);
  Result := FEntries[Index];
end;

function TImageList.NewEntry: LongInt;
begin
  Result := Length(FEntries);
  SetLength(FEntries, Result + 1);
  FEntries[Result] := TImageListEntry.Create;
end;

procedure TImageList.Clear;
var
  Index: LongInt;
begin
  for Index := 0 to High(FEntries) do
    FEntries[Index].Free;
  FEntries := nil;
end;

function TImageList.Add(Image: TImage): LongInt;
begin
  Result := NewEntry;
  FEntries[Result].AddVariant(Image.Clone);
end;

procedure TImageList.AddVariant(Index: LongInt; Image: TImage);
begin
  if ValidIndex(Index) then
    FEntries[Index].AddVariant(Image.Clone);
end;

function TImageList.AddIcon(const Data: TBytes): LongInt;
var
  Directory: TIconDirectory;
  Index: LongInt;
  Other: LongInt;
  Deepest: Boolean;
  Picture: TImage;
  Item: TImageListEntry;
begin
  Result := -1;
  try
    Directory := TIconDirectory.Create(Data);
  except
    on EImageError do
      Exit;
  end;
  Item := TImageListEntry.Create;
  try
    for Index := 0 to Directory.Count - 1 do
    begin
      { Only the deepest of the entries of a size (the first of equals). }
      Deepest := True;
      for Other := 0 to Directory.Count - 1 do
        if (Other <> Index) and (Directory.Entries[Other].Width = Directory.Entries[Index].Width) and
           (Directory.Entries[Other].Height = Directory.Entries[Index].Height) and
           ((Directory.Entries[Other].BitsPerPixel > Directory.Entries[Index].BitsPerPixel) or
            ((Directory.Entries[Other].BitsPerPixel = Directory.Entries[Index].BitsPerPixel) and (Other < Index))) then
          Deepest := False;
      if not Deepest then
        Continue;
      try
        Picture := DecodeIconEntry(Directory, Index);
        Item.AddVariant(Picture);
      except
        on EImageError do;
      end;
    end;
  finally
    Directory.Free;
  end;
  if Length(Item.FVariants) = 0 then
  begin
    Item.Free;
    Exit;
  end;
  Result := Length(FEntries);
  SetLength(FEntries, Result + 1);
  FEntries[Result] := Item;
end;

function TImageList.AddFromFile(const FileName: string): LongInt;
var
  Data: TBytes;
  Picture: TImage;
  Reason: TImageErrorReason;
begin
  Result := -1;
  try
    Data := ReadFileBytes(FileName);
  except
    on Exception do
      Exit;
  end;
  if LooksLikeIconFile(Data, IconTypeIcon) then
    Exit(AddIcon(Data));
  if not TryLoadImage(Data, Picture, Reason) then
    Exit;
  Result := NewEntry;
  FEntries[Result].AddVariant(Picture);
end;

function TImageList.StripFrameWidth(Strip: TImage): LongInt;
begin
  Result := Strip.Height;
  if FHeight > 0 then
    Result := (Int64(Strip.Height) * FWidth + FHeight div 2) div FHeight;
  if Result < 1 then
    Result := 1;
end;

{ Picture Index of a strip whose pictures are FrameWidth wide. }
function StripFrame(Strip: TImage; Index, FrameWidth: LongInt): TImage;
var
  Y: LongInt;
begin
  Result := TImage.Create(FrameWidth, Strip.Height);
  for Y := 0 to Strip.Height - 1 do
    Move(Strip.Line(Y)[Index * FrameWidth], Result.Line(Y)^, PtrUInt(FrameWidth) * SizeOf(LongWord));
end;

function TImageList.AddStrip(Strip: TImage): LongInt;
var
  FrameWidth: LongInt;
  Index: LongInt;
  Added: LongInt;
begin
  Result := -1;
  FrameWidth := StripFrameWidth(Strip);
  for Index := 0 to Strip.Width div FrameWidth - 1 do
  begin
    Added := NewEntry;
    if Result < 0 then
      Result := Added;
    FEntries[Added].AddVariant(StripFrame(Strip, Index, FrameWidth));
  end;
end;

procedure TImageList.AddStripVariants(FirstIndex: LongInt; Strip: TImage);
var
  FrameWidth: LongInt;
  Index: LongInt;
begin
  FrameWidth := StripFrameWidth(Strip);
  for Index := 0 to Strip.Width div FrameWidth - 1 do
    if ValidIndex(FirstIndex + Index) then
      FEntries[FirstIndex + Index].AddVariant(StripFrame(Strip, Index, FrameWidth));
end;

function TImageList.VariantCount(Index: LongInt): LongInt;
begin
  Result := 0;
  if ValidIndex(Index) then
    Result := Length(FEntries[Index].FVariants);
end;

function TImageList.Variant(Index, VariantIndex: LongInt): TImage;
begin
  Result := nil;
  if (VariantIndex >= 0) and (VariantIndex < VariantCount(Index)) then
    Result := FEntries[Index].FVariants[VariantIndex];
end;

{ The picture at Width x Height in its normal look: the variant of that
  size, or the best one resampled. A new image either way. }
function SizedImage(Item: TImageListEntry; Width, Height: LongInt): TImage;
var
  Sizes: array of TImagePixelSize;
  Index: LongInt;
  Best: TImage;
begin
  SetLength(Sizes, Length(Item.FVariants));
  for Index := 0 to High(Item.FVariants) do
    Sizes[Index] := MakeImagePixelSize(Item.FVariants[Index].Width, Item.FVariants[Index].Height);
  Best := Item.FVariants[BestImageSize(Sizes, MakeImagePixelSize(Width, Height))];
  if (Best.Width = Width) and (Best.Height = Height) then
    Result := Best.Clone
  else
    Result := ResampleImage(Best, Width, Height, ResamplingMitchell);
end;

function TImageList.PrepareImage(Item: TImageListEntry; Width, Height: LongInt; State: TImageDrawState): TImage;
var
  Index: LongInt;
  Normal: TImage;
begin
  for Index := 0 to High(Item.FPrepared) do
    if (Item.FPrepared[Index].Width = Width) and (Item.FPrepared[Index].Height = Height) and
       (Item.FPrepared[Index].State = State) then
      Exit(Item.FPrepared[Index].Image);
  if State = ImageDrawNormal then
    Result := SizedImage(Item, Width, Height)
  else
  begin
    Normal := PrepareImage(Item, Width, Height, ImageDrawNormal);
    if State = ImageDrawDisabled then
      Result := GreyedImage(Normal)
    else
      Result := TintedImage(Normal, Theme.Selection, SelectedTintWeight);
  end;
  Index := Length(Item.FPrepared);
  SetLength(Item.FPrepared, Index + 1);
  Item.FPrepared[Index].Width := Width;
  Item.FPrepared[Index].Height := Height;
  Item.FPrepared[Index].State := State;
  Item.FPrepared[Index].Image := Result;
end;

function TImageList.PreparedImage(Index, Width, Height: LongInt; State: TImageDrawState): TImage;
var
  Item: TImageListEntry;
begin
  Item := Entry(Index);
  if (Item = nil) or (Length(Item.FVariants) = 0) or (Width <= 0) or (Height <= 0) then
    Exit(nil);
  Result := PrepareImage(Item, Width, Height, State);
end;

procedure DrawPrepared(const Canvas: TCanvas; Picture: TImage; X, Y: LongInt);
begin
  if Picture = nil then
    Exit;
  DrawSurface(Canvas, ImageSurface(Picture), MakeRectangle(0, 0, Picture.Width, Picture.Height), X, Y, True,
    AlphaOpaque);
end;

procedure TImageList.Draw(const Canvas: TCanvas; Index, X, Y: LongInt; State: TImageDrawState);
begin
  DrawPrepared(Canvas, PreparedImage(Index, Scaled(FWidth), Scaled(FHeight), State), X, Y);
end;

procedure TImageList.DrawInBox(const Canvas: TCanvas; Index: LongInt; const Box: TRectangle; State: TImageDrawState);
var
  Fitted: TImagePixelSize;
begin
  Fitted := FitImagePixelSize(FWidth, FHeight, RectangleWidth(Box), RectangleHeight(Box));
  DrawPrepared(Canvas, PreparedImage(Index, Fitted.Width, Fitted.Height, State),
    Box.Left + (RectangleWidth(Box) - Fitted.Width) div 2, Box.Top + (RectangleHeight(Box) - Fitted.Height) div 2);
end;

end.
