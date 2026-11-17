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
  What the tools work with and tell about: the document and its
  selection, the primary and secondary colours (the left and right
  mouse buttons paint with them), the tools' settings (sizes, how
  shapes are filled, the fill's tolerance, the text's font), and how
  large an image pixel is in the view (so a "near" click is near on the
  screen).

  The window listens to what happens (OnImageChanged with the part of
  the picture that changed, or an empty rectangle for all of it, its
  size perhaps new; OnColorsChanged; OnToolWanted when a tool hands
  over to another, as the picker does when it has picked) and makes the
  text the text tool places (OnTextWanted), which needs fonts and a
  dialog.
}
unit Paint.Session;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Colors,
  Drawing.Rectangles,
  Image.Model,
  Paint.Document,
  Paint.SelectionEditing,
  Paint.ShapeDrawing,
  Paint.ToolKinds;

const
  SmallestToolSize = 1;
  LargestToolSize = 100;

type
  TToolSettings = record
    Sizes: array[TToolKind] of LongInt;
    FillStyle: TFillStyle;
    TolerancePercent: LongInt;
    { Windowing.Fonts' TFontFamily, as its number. }
    FontFamily: LongInt;
    FontPointTenths: LongWord;
    FontBold: Boolean;
  end;

  TPaintSession = class;
  TImageChangedEvent = procedure(Session: TPaintSession; const Area: TRectangle) of object;
  TSessionEvent = procedure(Session: TPaintSession) of object;
  TToolWantedEvent = procedure(Session: TPaintSession; Kind: TToolKind) of object;
  { The text to place, as an image of its own (nil: none). }
  TTextWantedEvent = function(Session: TPaintSession): TImage of object;

  TPaintSession = class
  private
    FDocument: TPaintDocument;
    FEditor: TSelectionEditor;
    FPrimaryColor: TColor;
    FSecondaryColor: TColor;
    FViewScale: Double;
    FOnImageChanged: TImageChangedEvent;
    FOnColorsChanged: TSessionEvent;
    FOnToolWanted: TToolWantedEvent;
    FOnTextWanted: TTextWantedEvent;
    procedure SetPrimaryColor(Value: TColor);
    procedure SetSecondaryColor(Value: TColor);
  public
    Settings: TToolSettings;
    { A session on a new picture (taken). }
    constructor Create(Image: TImage);
    destructor Destroy; override;
    { Area of the picture changed (empty: all of it). }
    procedure ImageChanged(const Area: TRectangle);
    procedure WholeImageChanged;
    procedure SwapColors;
    procedure WantTool(Kind: TToolKind);
    function TextWanted: TImage;
    { The size the current settings give Kind. }
    function ToolSize(Kind: TToolKind): LongInt;
    { Image pixels that make Pixels view pixels (at least 1). }
    function ViewPixelsToImage(Pixels: LongInt): LongInt;
    property Document: TPaintDocument read FDocument;
    property Editor: TSelectionEditor read FEditor;
    property PrimaryColor: TColor read FPrimaryColor write SetPrimaryColor;
    property SecondaryColor: TColor read FSecondaryColor write SetSecondaryColor;
    { View pixels per image pixel. }
    property ViewScale: Double read FViewScale write FViewScale;
    property OnImageChanged: TImageChangedEvent read FOnImageChanged write FOnImageChanged;
    property OnColorsChanged: TSessionEvent read FOnColorsChanged write FOnColorsChanged;
    property OnToolWanted: TToolWantedEvent read FOnToolWanted write FOnToolWanted;
    property OnTextWanted: TTextWantedEvent read FOnTextWanted write FOnTextWanted;
  end;

function DefaultToolSettings: TToolSettings;

implementation

uses
  Math;

const
  DefaultTolerancePercent = 10;
  DefaultFontPointTenths = 240;

function DefaultToolSettings: TToolSettings;
var
  Kind: TToolKind;
begin
  for Kind := Low(TToolKind) to High(TToolKind) do
    Result.Sizes[Kind] := 2;
  Result.Sizes[ToolBrush] := 6;
  Result.Sizes[ToolEraser] := 8;
  Result.Sizes[ToolAirbrush] := 16;
  Result.FillStyle := FillStyleOutline;
  Result.TolerancePercent := DefaultTolerancePercent;
  Result.FontFamily := 0;
  Result.FontPointTenths := DefaultFontPointTenths;
  Result.FontBold := False;
end;

constructor TPaintSession.Create(Image: TImage);
begin
  inherited Create;
  FDocument := TPaintDocument.Create(Image);
  FEditor := TSelectionEditor.Create(FDocument);
  FPrimaryColor := ColorBlack;
  FSecondaryColor := ColorWhite;
  FViewScale := 1;
  Settings := DefaultToolSettings;
end;

destructor TPaintSession.Destroy;
begin
  FEditor.Free;
  FDocument.Free;
  inherited Destroy;
end;

procedure TPaintSession.ImageChanged(const Area: TRectangle);
begin
  if Assigned(FOnImageChanged) then
    FOnImageChanged(Self, Area);
end;

procedure TPaintSession.WholeImageChanged;
begin
  ImageChanged(MakeRectangle(0, 0, 0, 0));
end;

procedure TPaintSession.SetPrimaryColor(Value: TColor);
begin
  FPrimaryColor := Value;
  if Assigned(FOnColorsChanged) then
    FOnColorsChanged(Self);
end;

procedure TPaintSession.SetSecondaryColor(Value: TColor);
begin
  FSecondaryColor := Value;
  if Assigned(FOnColorsChanged) then
    FOnColorsChanged(Self);
end;

procedure TPaintSession.SwapColors;
var
  Kept: TColor;
begin
  Kept := FPrimaryColor;
  FPrimaryColor := FSecondaryColor;
  SetSecondaryColor(Kept);
end;

procedure TPaintSession.WantTool(Kind: TToolKind);
begin
  if Assigned(FOnToolWanted) then
    FOnToolWanted(Self, Kind);
end;

function TPaintSession.TextWanted: TImage;
begin
  Result := nil;
  if Assigned(FOnTextWanted) then
    Result := FOnTextWanted(Self);
end;

function TPaintSession.ToolSize(Kind: TToolKind): LongInt;
begin
  Result := EnsureRange(Settings.Sizes[Kind], SmallestToolSize, LargestToolSize);
end;

function TPaintSession.ViewPixelsToImage(Pixels: LongInt): LongInt;
begin
  Result := Max(1, Round(Pixels / FViewScale));
end;

end.
