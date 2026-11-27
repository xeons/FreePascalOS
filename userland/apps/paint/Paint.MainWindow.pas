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
  Paint's window with its menus (File, Edit, View, Image, Colours,
  Tools, Help), their accelerators, the current tool, and the status
  bar (what the tool does, the pointer's pixel, the selection's size,
  the picture's size, the zoom).

  The Edit menu's items are enabled as things are when it opens (Undo
  with something to undo, Cut, Copy, Delete and Crop with a selection,
  Paste with a picture on the clipboard). Copy and Cut put the selected
  pixels on the system clipboard as PNG and raw pixels
  (Controls.ImageClipboard), so any program can paste them; Paste
  floats the clipboard's picture at the top left of what is shown, to
  be dragged into place (a picture larger than the canvas offers to
  enlarge the canvas first). The tool changes with the tool box's
  buttons or the Tools menu; anything a tool has under way is finished
  first. The pixel grid and the status bar are remembered
  (Paint.Settings), as is the text tool's font.
}
unit Paint.MainWindow;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Image.Model,
  Controls.Base,
  Controls.Menus,
  Paint.Session,
  Paint.ToolKinds,
  Paint.Tools,
  Paint.CanvasView,
  Paint.DocumentWindow;

type
  TPaintWindow = class(TDocumentWindow)
  private
    FMenuBar: TMenuBar;
    FTool: TPaintTool;
    FToolKind: TToolKind;
    FPendingTool: TToolKind;
    FHasPendingTool: Boolean;
    FToolItems: array[TToolKind] of TMenuItem;
    FUndoItem: TMenuItem;
    FRedoItem: TMenuItem;
    FCutItem: TMenuItem;
    FCopyItem: TMenuItem;
    FPasteItem: TMenuItem;
    FDeleteItem: TMenuItem;
    FCropItem: TMenuItem;
    FGridItem: TMenuItem;
    FStatusBarItem: TMenuItem;
    FLastText: string;
    procedure BuildMenus;
    procedure BuildFileMenu;
    procedure BuildEditMenu;
    procedure BuildViewMenu;
    procedure BuildImageMenu;
    procedure BuildColorsMenu;
    procedure BuildToolsMenu;
    function AddItem(Menu: TMenuItem; const Text: string; Handler: TMenuItemEvent; const Shortcut: string;
      Code, Modifiers: LongWord): TMenuItem;
    procedure PlaceStatusPanels;
    procedure ShowStatus;
    procedure ShowPointer(Inside: Boolean; X, Y: LongInt);
    { Session and view events. }
    procedure SessionImageChanged(ASession: TPaintSession; const Area: TRectangle);
    procedure SessionColorsChanged(ASession: TPaintSession);
    procedure SessionToolWanted(ASession: TPaintSession; Kind: TToolKind);
    function SessionTextWanted(ASession: TPaintSession): TImage;
    procedure ViewPointerPlace(View: TCanvasView; Inside: Boolean; X, Y: LongInt);
    procedure ViewToolEventDone(View: TCanvasView);
    procedure ViewZoomChanged(View: TCanvasView);
    procedure ToolBoxToolChosen(Kind: TToolKind);
    procedure ToolBoxOptionsChanged;
    procedure ToolBoxFontWanted;
    procedure ColorBoxEditPrimary;
    { Menus. }
    procedure EditMenuOpening(Item: TMenuItem);
    procedure NewChosen(Item: TMenuItem);
    procedure OpenChosen(Item: TMenuItem);
    procedure SaveChosen(Item: TMenuItem);
    procedure SaveAsChosen(Item: TMenuItem);
    procedure ExitChosen(Item: TMenuItem);
    procedure UndoChosen(Item: TMenuItem);
    procedure RedoChosen(Item: TMenuItem);
    procedure CutChosen(Item: TMenuItem);
    procedure CopyChosen(Item: TMenuItem);
    procedure PasteChosen(Item: TMenuItem);
    procedure DeleteChosen(Item: TMenuItem);
    procedure SelectAllChosen(Item: TMenuItem);
    procedure CropChosen(Item: TMenuItem);
    procedure ZoomInChosen(Item: TMenuItem);
    procedure ZoomOutChosen(Item: TMenuItem);
    procedure ActualSizeChosen(Item: TMenuItem);
    procedure GridChosen(Item: TMenuItem);
    procedure StatusBarChosen(Item: TMenuItem);
    procedure ResizeChosen(Item: TMenuItem);
    procedure RotateClockwiseChosen(Item: TMenuItem);
    procedure RotateAnticlockwiseChosen(Item: TMenuItem);
    procedure RotateHalfChosen(Item: TMenuItem);
    procedure FlipAcrossChosen(Item: TMenuItem);
    procedure FlipUpDownChosen(Item: TMenuItem);
    procedure InvertChosen(Item: TMenuItem);
    procedure PropertiesChosen(Item: TMenuItem);
    procedure ClearChosen(Item: TMenuItem);
    procedure EditPrimaryChosen(Item: TMenuItem);
    procedure EditSecondaryChosen(Item: TMenuItem);
    procedure SwapColorsChosen(Item: TMenuItem);
    procedure ToolChosen(Item: TMenuItem);
    procedure AboutChosen(Item: TMenuItem);
    procedure CopySelection(Cutting: Boolean);
  protected
    procedure Resized; override;
    procedure FinishWork; override;
    procedure PictureReplaced; override;
  public
    constructor Create;
    destructor Destroy; override;
    procedure SelectTool(Kind: TToolKind);
    { Prints where the picture's top left and the tools' buttons are on
      the screen (for tests). }
    procedure TellPlaces;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Drawing.Colors,
  Windowing.Windows,
  Controls.Keys,
  Controls.MessageBoxes,
  Controls.Dialogs,
  Controls.ColorDialog,
  Controls.ImageClipboard,
  Image.Areas,
  Paint.Keys,
  Paint.ZoomMapping,
  Paint.ToolFactory,
  Paint.FillTools,
  Paint.ImageCommands,
  Paint.ImageSizeDialog,
  Paint.ResizeDialog,
  Paint.TextDialog,
  Paint.TextRendering,
  Paint.Settings,
  Paint.Output;

const
  NoKey = 0;
  { Logical units: the status bar's panels after the first. }
  PointerPanelWidth = 110;
  SelectionPanelWidth = 110;
  SizePanelWidth = 110;
  ZoomPanelWidth = 60;
  FirstTool = ToolPencil;

constructor TPaintWindow.Create;
var
  Preferences: TPaintPreferences;
begin
  inherited Create;
  BuildMenus;
  Preferences := RememberedPreferences;
  FSession.Settings.FontFamily := Preferences.FontFamily;
  FSession.Settings.FontPointTenths := Preferences.FontPointTenths;
  FSession.Settings.FontBold := Preferences.FontBold;
  FGridItem.Checked := FView.ShowGrid;
  FStatusBarItem.Checked := FStatusBar.Visible;
  FSession.OnImageChanged := @SessionImageChanged;
  FSession.OnColorsChanged := @SessionColorsChanged;
  FSession.OnToolWanted := @SessionToolWanted;
  FSession.OnTextWanted := @SessionTextWanted;
  FView.OnPointerPlace := @ViewPointerPlace;
  FView.OnToolEventDone := @ViewToolEventDone;
  FView.OnZoomChanged := @ViewZoomChanged;
  FToolBox.OnToolChosen := @ToolBoxToolChosen;
  FToolBox.OnOptionsChanged := @ToolBoxOptionsChanged;
  FToolBox.OnFontWanted := @ToolBoxFontWanted;
  FColorBox.OnEditPrimary := @ColorBoxEditPrimary;
  PlaceStatusPanels;
  SelectTool(FirstTool);
  UpdateTitle;
end;

destructor TPaintWindow.Destroy;
begin
  FView.Tool := nil;
  FTool.Free;
  inherited Destroy;
end;

function TPaintWindow.AddItem(Menu: TMenuItem; const Text: string; Handler: TMenuItemEvent;
  const Shortcut: string; Code, Modifiers: LongWord): TMenuItem;
begin
  Result := Menu.Add(Text, Handler, Shortcut);
  if Code <> NoKey then
    AddItemAccelerator(Self, Result, Code, Modifiers);
end;

procedure TPaintWindow.BuildMenus;
var
  Menu: TMenuItem;
begin
  FMenuBar := TMenuBar.Create(Root);
  BuildFileMenu;
  BuildEditMenu;
  BuildViewMenu;
  BuildImageMenu;
  BuildColorsMenu;
  BuildToolsMenu;
  Menu := FMenuBar.Menu.Add('&Help');
  AddItem(Menu, '&About Paint', @AboutChosen, '', NoKey, 0);
end;

procedure TPaintWindow.BuildFileMenu;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&File');
  AddItem(Menu, '&New...', @NewChosen, 'Ctrl+N', KeyN, ModifierControl);
  AddItem(Menu, '&Open...', @OpenChosen, 'Ctrl+O', KeyO, ModifierControl);
  AddItem(Menu, '&Save', @SaveChosen, 'Ctrl+S', KeyS, ModifierControl);
  AddItem(Menu, 'Save &As...', @SaveAsChosen, '', NoKey, 0);
  Menu.AddSeparator;
  AddItem(Menu, 'E&xit', @ExitChosen, '', NoKey, 0);
end;

procedure TPaintWindow.BuildEditMenu;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&Edit');
  Menu.OnOpening := @EditMenuOpening;
  FUndoItem := AddItem(Menu, '&Undo', @UndoChosen, 'Ctrl+Z', KeyZ, ModifierControl);
  FRedoItem := AddItem(Menu, '&Redo', @RedoChosen, 'Ctrl+Y', KeyY, ModifierControl);
  Menu.AddSeparator;
  FCutItem := AddItem(Menu, 'Cu&t', @CutChosen, 'Ctrl+X', KeyX, ModifierControl);
  FCopyItem := AddItem(Menu, '&Copy', @CopyChosen, 'Ctrl+C', KeyC, ModifierControl);
  FPasteItem := AddItem(Menu, '&Paste', @PasteChosen, 'Ctrl+V', KeyV, ModifierControl);
  { The Delete key is the selection tools' own (an accelerator would take
    it from the tool box's boxes). }
  FDeleteItem := AddItem(Menu, 'De&lete', @DeleteChosen, 'Del', NoKey, 0);
  AddItem(Menu, 'Select &All', @SelectAllChosen, 'Ctrl+A', KeyA, ModifierControl);
  Menu.AddSeparator;
  FCropItem := AddItem(Menu, 'Cr&op to Selection', @CropChosen, 'Ctrl+Shift+X', KeyX,
    ModifierControl or ModifierShift);
end;

procedure TPaintWindow.BuildViewMenu;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&View');
  AddItem(Menu, 'Zoom &In', @ZoomInChosen, 'Ctrl+PgUp', KeyPageUp, ModifierControl);
  AddItem(Menu, 'Zoom &Out', @ZoomOutChosen, 'Ctrl+PgDn', KeyPageDown, ModifierControl);
  AddItem(Menu, '&Actual Size', @ActualSizeChosen, 'Ctrl+0', KeyDigitZero, ModifierControl);
  Menu.AddSeparator;
  FGridItem := AddItem(Menu, 'Pixel &Grid', @GridChosen, 'Ctrl+G', KeyG, ModifierControl);
  FStatusBarItem := AddItem(Menu, '&Status Bar', @StatusBarChosen, '', NoKey, 0);
  { Ctrl with + and - too, as other programs zoom. }
  AddItemAccelerator(Self, Menu[0], KeyEquals, ModifierControl);
  AddItemAccelerator(Self, Menu[1], KeyMinus, ModifierControl);
end;

procedure TPaintWindow.BuildImageMenu;
var
  Menu: TMenuItem;
  Turn: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&Image');
  AddItem(Menu, '&Resize and Skew...', @ResizeChosen, 'Ctrl+W', KeyW, ModifierControl);
  Turn := Menu.Add('Rotate and &Flip');
  AddItem(Turn, 'Rotate &Right 90°', @RotateClockwiseChosen, '', NoKey, 0);
  AddItem(Turn, 'Rotate &Left 90°', @RotateAnticlockwiseChosen, '', NoKey, 0);
  AddItem(Turn, 'Rotate &180°', @RotateHalfChosen, '', NoKey, 0);
  AddItem(Turn, 'Flip &Horizontally', @FlipAcrossChosen, '', NoKey, 0);
  AddItem(Turn, 'Flip &Vertically', @FlipUpDownChosen, '', NoKey, 0);
  AddItem(Menu, '&Invert Colours', @InvertChosen, 'Ctrl+I', KeyI, ModifierControl);
  Menu.AddSeparator;
  AddItem(Menu, '&Properties...', @PropertiesChosen, 'Ctrl+E', KeyE, ModifierControl);
  AddItem(Menu, '&Clear Image', @ClearChosen, 'Ctrl+Shift+N', KeyN, ModifierControl or ModifierShift);
end;

procedure TPaintWindow.BuildColorsMenu;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&Colours');
  AddItem(Menu, 'Edit &Primary Colour...', @EditPrimaryChosen, '', NoKey, 0);
  AddItem(Menu, 'Edit &Secondary Colour...', @EditSecondaryChosen, '', NoKey, 0);
  AddItem(Menu, 'S&wap Colours', @SwapColorsChosen, '', NoKey, 0);
end;

procedure TPaintWindow.BuildToolsMenu;
var
  Menu: TMenuItem;
  Kind: TToolKind;
begin
  Menu := FMenuBar.Menu.Add('&Tools');
  for Kind := Low(TToolKind) to High(TToolKind) do
  begin
    FToolItems[Kind] := AddItem(Menu, ToolCaptions[Kind], @ToolChosen, '', NoKey, 0);
    FToolItems[Kind].Tag := Ord(Kind);
  end;
end;

{ --- Tools ------------------------------------------------------------------------------------- }

procedure TPaintWindow.SelectTool(Kind: TToolKind);
var
  Previous: TToolKind;
  Each: TToolKind;
begin
  Previous := FToolKind;
  if FTool <> nil then
  begin
    FTool.Finish;
    FView.Tool := nil;
    FreeAndNil(FTool);
  end;
  FToolKind := Kind;
  FTool := CreateTool(Kind, FSession);
  if FTool is TPickerTool then
    TPickerTool(FTool).PreviousTool := Ord(Previous);
  FView.Tool := FTool;
  FToolBox.ShowTool(Kind);
  for Each := Low(TToolKind) to High(TToolKind) do
    FToolItems[Each].Checked := Each = Kind;
  Say('tool ' + ToolWords[Kind]);
  ShowStatus;
end;

procedure TPaintWindow.ToolChosen(Item: TMenuItem);
begin
  SelectTool(TToolKind(Item.Tag));
end;

procedure TPaintWindow.ToolBoxToolChosen(Kind: TToolKind);
begin
  SelectTool(Kind);
  FocusControl(FView.Area);
end;

procedure TPaintWindow.ToolBoxOptionsChanged;
begin
  ShowStatus;
end;

procedure TPaintWindow.ToolBoxFontWanted;
var
  Family: LongInt;
  PointTenths: LongWord;
  Bold: Boolean;
begin
  Family := FSession.Settings.FontFamily;
  PointTenths := FSession.Settings.FontPointTenths;
  Bold := FSession.Settings.FontBold;
  if not AskForTextFont(Family, PointTenths, Bold) then
    Exit;
  FSession.Settings.FontFamily := Family;
  FSession.Settings.FontPointTenths := PointTenths;
  FSession.Settings.FontBold := Bold;
  RememberTextFont(Family, PointTenths, Bold);
end;

procedure TPaintWindow.FinishWork;
begin
  if FTool <> nil then
    FTool.Finish;
  inherited FinishWork;
end;

procedure TPaintWindow.PictureReplaced;
begin
  if FTool <> nil then
    FTool.Cancel;
  inherited PictureReplaced;
end;

{ --- Session and view events ----------------------------------------------------------------- }

procedure TPaintWindow.SessionImageChanged(ASession: TPaintSession; const Area: TRectangle);
begin
  FView.ImageChanged(Area);
  if RectangleIsEmpty(Area) then
    ShowStatus;
end;

procedure TPaintWindow.SessionColorsChanged(ASession: TPaintSession);
begin
  FColorBox.ShowColors;
  Say(Format('colours %.8x %.8x', [FSession.PrimaryColor, FSession.SecondaryColor]));
end;

procedure TPaintWindow.SessionToolWanted(ASession: TPaintSession; Kind: TToolKind);
begin
  { Changed once the tool asking has finished (ViewToolEventDone). }
  FPendingTool := Kind;
  FHasPendingTool := True;
end;

function TPaintWindow.SessionTextWanted(ASession: TPaintSession): TImage;
var
  Text: string;
  Family: LongInt;
  PointTenths: LongWord;
  Bold: Boolean;
begin
  Result := nil;
  Text := FLastText;
  Family := FSession.Settings.FontFamily;
  PointTenths := FSession.Settings.FontPointTenths;
  Bold := FSession.Settings.FontBold;
  if not AskForText(Self, Text, Family, PointTenths, Bold) or (Text = '') then
    Exit;
  FLastText := Text;
  FSession.Settings.FontFamily := Family;
  FSession.Settings.FontPointTenths := PointTenths;
  FSession.Settings.FontBold := Bold;
  RememberTextFont(Family, PointTenths, Bold);
  Result := RenderTextImage(Text, Family, PointTenths, Bold, FSession.PrimaryColor);
  if Result <> nil then
    Say('text ' + Text);
end;

procedure TPaintWindow.ViewPointerPlace(View: TCanvasView; Inside: Boolean; X, Y: LongInt);
begin
  ShowPointer(Inside, X, Y);
end;

procedure TPaintWindow.ViewToolEventDone(View: TCanvasView);
begin
  if FHasPendingTool then
  begin
    FHasPendingTool := False;
    SelectTool(FPendingTool);
  end;
  ShowStatus;
end;

procedure TPaintWindow.ViewZoomChanged(View: TCanvasView);
begin
  Say('zoom ' + ZoomText(FView.Zoom));
  ShowStatus;
end;

procedure TPaintWindow.ColorBoxEditPrimary;
begin
  EditPrimaryChosen(nil);
end;

{ --- The status bar ---------------------------------------------------------------------------- }

procedure TPaintWindow.PlaceStatusPanels;
begin
  FStatusBar.SetPanels([ClientWidth - PointerPanelWidth - SelectionPanelWidth - SizePanelWidth - ZoomPanelWidth,
    PointerPanelWidth, SelectionPanelWidth, SizePanelWidth, ZoomPanelWidth]);
end;

procedure TPaintWindow.Resized;
begin
  inherited Resized;
  if FStatusBar <> nil then
    PlaceStatusPanels;
end;

procedure TPaintWindow.ShowStatus;
var
  Selection: TRectangle;
begin
  if FStatusBar = nil then
    Exit;
  FStatusBar.PanelText[0] := ' ' + ToolHints[FToolKind];
  if FSession.Editor.Selection.Active then
  begin
    Selection := FSession.Editor.Area;
    FStatusBar.PanelText[2] := Format(' %d x %d px', [RectangleWidth(Selection), RectangleHeight(Selection)]);
  end
  else
    FStatusBar.PanelText[2] := '';
  FStatusBar.PanelText[3] := Format(' %d x %d px', [FSession.Document.Image.Width,
    FSession.Document.Image.Height]);
  FStatusBar.PanelText[4] := ' ' + ZoomText(FView.Zoom);
end;

procedure TPaintWindow.ShowPointer(Inside: Boolean; X, Y: LongInt);
begin
  if Inside then
    FStatusBar.PanelText[1] := Format(' %d, %d px', [X, Y])
  else
    FStatusBar.PanelText[1] := '';
end;

procedure TPaintWindow.TellPlaces;
var
  Corner: TPoint;
  Kind: TToolKind;
  Button: TControl;
begin
  Corner := FView.ViewPointOf(0, 0);
  TellPlace('canvas', FView.Area, Corner.X, Corner.Y);
  for Kind := Low(TToolKind) to High(TToolKind) do
  begin
    Button := FToolBox.ButtonOf(Kind);
    TellPlace('tool-' + ToolWords[Kind], Button, RectangleWidth(Button.PixelBounds) div 2,
      RectangleHeight(Button.PixelBounds) div 2);
  end;
end;

{ --- File -------------------------------------------------------------------------------------- }

procedure TPaintWindow.NewChosen(Item: TMenuItem);
begin
  NewDocument;
end;

procedure TPaintWindow.OpenChosen(Item: TMenuItem);
begin
  ChooseAndOpenDocument;
end;

procedure TPaintWindow.SaveChosen(Item: TMenuItem);
begin
  SaveDocument;
end;

procedure TPaintWindow.SaveAsChosen(Item: TMenuItem);
begin
  SaveDocumentAs;
end;

procedure TPaintWindow.ExitChosen(Item: TMenuItem);
begin
  ExitIfAllowed;
end;

{ --- Edit -------------------------------------------------------------------------------------- }

procedure TPaintWindow.EditMenuOpening(Item: TMenuItem);
var
  Selected: Boolean;
begin
  Selected := FSession.Editor.Selection.Active;
  FUndoItem.Enabled := FSession.Document.CanUndo or (FTool <> nil) and FTool.Busy;
  FRedoItem.Enabled := FSession.Document.CanRedo;
  FCutItem.Enabled := Selected;
  FCopyItem.Enabled := Selected;
  FDeleteItem.Enabled := Selected;
  FCropItem.Enabled := Selected;
  FPasteItem.Enabled := ClipboardHoldsImage;
end;

procedure TPaintWindow.UndoChosen(Item: TMenuItem);
var
  Area: TRectangle;
  Size: TRectangle;
begin
  FinishWork;
  Size := ImageBounds(FSession.Document.Image);
  if not FSession.Document.Undo(Area) then
    Exit;
  FSession.Editor.Forget;
  if RectangleIsEmpty(Area) or not RectanglesAreEqual(Size, ImageBounds(FSession.Document.Image)) then
    FSession.WholeImageChanged
  else
    FSession.ImageChanged(InflateRectangle(Area, 1));
  Say('undone');
end;

procedure TPaintWindow.RedoChosen(Item: TMenuItem);
var
  Area: TRectangle;
begin
  FinishWork;
  if not FSession.Document.Redo(Area) then
    Exit;
  FSession.Editor.Forget;
  if RectangleIsEmpty(Area) then
    FSession.WholeImageChanged
  else
    FSession.ImageChanged(InflateRectangle(Area, 1));
  Say('redone');
end;

procedure TPaintWindow.CopySelection(Cutting: Boolean);
var
  Pixels: TImage;
  Area: TRectangle;
begin
  Pixels := FSession.Editor.CopySelected;
  if Pixels = nil then
    Exit;
  try
    CopyImageToClipboard(Pixels.Clone);
    Say(Format('copied %d %d', [Pixels.Width, Pixels.Height]));
  finally
    Pixels.Free;
  end;
  if Cutting then
  begin
    Area := FSession.Editor.Area;
    FSession.Editor.DeleteSelected(FSession.SecondaryColor);
    FSession.ImageChanged(InflateRectangle(Area, 1));
  end;
end;

procedure TPaintWindow.CutChosen(Item: TMenuItem);
begin
  CopySelection(True);
end;

procedure TPaintWindow.CopyChosen(Item: TMenuItem);
begin
  CopySelection(False);
end;

procedure TPaintWindow.PasteChosen(Item: TMenuItem);
var
  Pasted: TImage;
  Image: TImage;
  Corner: TPoint;
  Answer: LongInt;
begin
  Pasted := ReadClipboardImage;
  if Pasted = nil then
    Exit;
  if FTool <> nil then
    FTool.Finish;
  Image := FSession.Document.Image;
  if (Pasted.Width > Image.Width) or (Pasted.Height > Image.Height) then
  begin
    Answer := ShowMessageBox('Paint', 'The picture on the clipboard is larger than the canvas.'#10#10 +
      'Do you want the canvas enlarged?', MessageYesNoCancel, SignQuestion, Self);
    if Answer = ResultCancel then
    begin
      Pasted.Free;
      Exit;
    end;
    if Answer = ResultYes then
      ChangeCanvasSize(FSession, Pasted.Width, Pasted.Height);
  end;
  { The selection tool, so the pasted picture can be dragged. }
  if not (FToolKind in [ToolSelect, ToolFreeFormSelect]) then
    SelectTool(ToolSelect);
  Corner := FView.VisibleTopLeft;
  FSession.Editor.PasteImage(Pasted, Corner.X, Corner.Y);
  FSession.ImageChanged(InflateRectangle(FSession.Editor.Area, 1));
  Say(Format('pasted %d %d', [Pasted.Width, Pasted.Height]));
  ShowStatus;
end;

procedure TPaintWindow.DeleteChosen(Item: TMenuItem);
var
  Area: TRectangle;
begin
  if not FSession.Editor.Selection.Active then
    Exit;
  Area := FSession.Editor.Area;
  FSession.Editor.DeleteSelected(FSession.SecondaryColor);
  FSession.ImageChanged(InflateRectangle(Area, 1));
  ShowStatus;
end;

procedure TPaintWindow.SelectAllChosen(Item: TMenuItem);
begin
  if not (FToolKind in [ToolSelect, ToolFreeFormSelect]) then
    SelectTool(ToolSelect);
  FSession.Editor.SelectAll;
  FSession.WholeImageChanged;
end;

procedure TPaintWindow.CropChosen(Item: TMenuItem);
begin
  if FSession.Editor.CropToSelection then
  begin
    FSession.WholeImageChanged;
    Say(Format('image %d %d', [FSession.Document.Image.Width, FSession.Document.Image.Height]));
  end;
end;

{ --- View -------------------------------------------------------------------------------------- }

procedure TPaintWindow.ZoomInChosen(Item: TMenuItem);
begin
  FView.SetZoom(ZoomedIn(FView.Zoom));
end;

procedure TPaintWindow.ZoomOutChosen(Item: TMenuItem);
begin
  FView.SetZoom(ZoomedOut(FView.Zoom));
end;

procedure TPaintWindow.ActualSizeChosen(Item: TMenuItem);
begin
  FView.SetZoom(ActualSizeZoom);
end;

procedure TPaintWindow.GridChosen(Item: TMenuItem);
begin
  FView.ShowGrid := not FView.ShowGrid;
  FGridItem.Checked := FView.ShowGrid;
  RememberPixelGrid(FView.ShowGrid);
end;

procedure TPaintWindow.StatusBarChosen(Item: TMenuItem);
begin
  FStatusBar.Visible := not FStatusBar.Visible;
  FStatusBarItem.Checked := FStatusBar.Visible;
  RememberStatusBar(FStatusBar.Visible);
end;

{ --- Image ------------------------------------------------------------------------------------- }

procedure TPaintWindow.ResizeChosen(Item: TMenuItem);
var
  Choice: TResizeChoice;
begin
  FinishWork;
  if not AskForResize(Self, FSession.Document.Image.Width, FSession.Document.Image.Height, Choice) then
    Exit;
  ResizePicture(FSession, Choice.NewWidth, Choice.NewHeight, Choice.SkewHorizontal, Choice.SkewVertical);
  Say(Format('image %d %d', [FSession.Document.Image.Width, FSession.Document.Image.Height]));
end;

procedure TPaintWindow.RotateClockwiseChosen(Item: TMenuItem);
begin
  FinishWork;
  TurnPicture(FSession, TurnClockwise);
end;

procedure TPaintWindow.RotateAnticlockwiseChosen(Item: TMenuItem);
begin
  FinishWork;
  TurnPicture(FSession, TurnAnticlockwise);
end;

procedure TPaintWindow.RotateHalfChosen(Item: TMenuItem);
begin
  FinishWork;
  TurnPicture(FSession, TurnHalf);
end;

procedure TPaintWindow.FlipAcrossChosen(Item: TMenuItem);
begin
  FinishWork;
  FlipPicture(FSession, True);
end;

procedure TPaintWindow.FlipUpDownChosen(Item: TMenuItem);
begin
  FinishWork;
  FlipPicture(FSession, False);
end;

procedure TPaintWindow.InvertChosen(Item: TMenuItem);
begin
  FinishWork;
  InvertPicture(FSession);
end;

procedure TPaintWindow.PropertiesChosen(Item: TMenuItem);
var
  Image: TImage;
  Width: LongInt;
  Height: LongInt;
  Details: string;
begin
  FinishWork;
  Image := FSession.Document.Image;
  Details := 'File: ' + DocumentName;
  if Image.SourceFormatName <> '' then
    Details := Details + ' (' + Image.SourceFormatName + ')';
  if Image.Resolution.HorizontalDpi > 0 then
    Details := Details + Format(', %d dpi', [Round(Image.Resolution.HorizontalDpi)]);
  Width := Image.Width;
  Height := Image.Height;
  if not AskForImageSize(Self, 'Picture properties', Details, Width, Height) then
    Exit;
  ChangeCanvasSize(FSession, Width, Height);
  Say(Format('image %d %d', [FSession.Document.Image.Width, FSession.Document.Image.Height]));
end;

procedure TPaintWindow.ClearChosen(Item: TMenuItem);
begin
  FinishWork;
  ClearPicture(FSession);
end;

{ --- Colours ----------------------------------------------------------------------------------- }

procedure TPaintWindow.EditPrimaryChosen(Item: TMenuItem);
var
  Color: TColor;
begin
  Color := FSession.PrimaryColor;
  if ChooseColor(Color) then
    FSession.PrimaryColor := Color;
end;

procedure TPaintWindow.EditSecondaryChosen(Item: TMenuItem);
var
  Color: TColor;
begin
  Color := FSession.SecondaryColor;
  if ChooseColor(Color) then
    FSession.SecondaryColor := Color;
end;

procedure TPaintWindow.SwapColorsChosen(Item: TMenuItem);
begin
  FSession.SwapColors;
end;

{ --- Help -------------------------------------------------------------------------------------- }

procedure TPaintWindow.AboutChosen(Item: TMenuItem);
begin
  ShowMessageBox('About Paint', 'Paint'#10'A program for drawing and editing pictures, for FreePascalOS.',
    MessageOk, SignInformation, Self);
end;

end.
