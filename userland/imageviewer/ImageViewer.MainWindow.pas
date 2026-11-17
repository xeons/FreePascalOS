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
  The image viewer's window: menus, a toolbar, the view
  (ImageViewer.ImageView) and the properties panel side by side in a
  split container (the panel collapsed while hidden), and a status bar
  with the file, its size, the zoom and an animation's frame. Every
  part docks or fills; nothing is placed by hand.

    File   Open... (Ctrl+O), Save As... (Ctrl+S), Next (Right, Page
           Down), Previous (Left, Page Up), Properties (Alt+Enter), Exit
    Edit   Copy (Ctrl+C: the picture as shown, on the system clipboard)
    View   Zoom In (+, Ctrl+wheel), Zoom Out (-), Actual Size (Ctrl+0),
           Fit to Window (Ctrl+F), Full Screen (F11, Escape leaves),
           Toolbar, Status Bar, Colour Management (convert to sRGB)
    Image  Rotate Right (Ctrl+R), Rotate Left (Ctrl+L), Flip
           Horizontally, Flip Vertically
    Animation  Play/Pause (Space), Next Frame (.), Previous Frame (,)
    Help   About Image Viewer

  An image comes from the command line, the open dialog, or files
  dropped anywhere on the window; Next and Previous go through the
  images of its folder (ImageViewer.FolderImages). Colour management,
  the panels and the bars are kept in the user's settings
  (ImageViewer.Settings) and taken again when they change elsewhere.
}
unit ImageViewer.MainWindow;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Configuration.Changes,
  Image.Model,
  Controls.Base,
  Controls.DragData,
  Controls.Window,
  Controls.Menus,
  Controls.ToolBar,
  Controls.StatusBar,
  Controls.ListView,
  Controls.SplitContainer,
  ImageViewer.Orientations,
  ImageViewer.Properties,
  ImageViewer.ImageView;

type
  TImageViewerWindow = class(TControlWindow)
  private
    FMenuBar: TMenuBar;
    FToolBar: TToolBar;
    FStatusBar: TStatusBar;
    FSplit: TSplitContainer;
    FView: TImageView;
    FProperties: TListView;
    FPath: string;
    FFileSize: Int64;
    FFolderImages: TStringList;
    FTurn: TViewTurn;
    FColorHandling: TColorHandling;
    FColorManagement: Boolean;
    FFullScreen: Boolean;
    FPlayButton: TToolButton;
    FPropertiesItem: TMenuItem;
    FToolBarItem: TMenuItem;
    FStatusBarItem: TMenuItem;
    FColorItem: TMenuItem;
    FFullScreenItem: TMenuItem;
    FPlayItem: TMenuItem;
    FNextFrameItem: TMenuItem;
    FPreviousFrameItem: TMenuItem;
    procedure BuildMenus;
    procedure BuildFileAndEditMenus;
    procedure BuildViewMenu;
    procedure BuildImageAndAnimationMenus;
    procedure BuildToolBar;
    procedure BuildPanels;
    function AddItem(Menu: TMenuItem; const Text: string; Handler: TMenuItemEvent; const Shortcut: string;
      Code, Modifiers: LongWord): TMenuItem;
    function HasImage: Boolean;
    function IsAnimation: Boolean;
    function StartFolder: string;
    procedure ShowProperties;
    procedure ShowStatus;
    procedure PlaceStatusPanels;
    procedure UpdateTitle;
    procedure UpdateAnimationCommands;
    procedure ApplyTurn;
    procedure ApplySettings;
    procedure SetPropertiesShown(Shown: Boolean);
    procedure SetFullScreen(Value: Boolean);
    procedure Navigate(Step: LongInt);
    procedure StepFrame(Step: LongInt);
    procedure TogglePlaying;
    procedure ZoomChanged(Sender: TControl);
    procedure SplitterMoved(Sender: TControl);
    procedure RootDragOver(Sender: TControl; Data: TDragData; X, Y: LongInt; Modifiers: LongWord;
      var Effect: TDropEffect);
    procedure RootDragDrop(Sender: TControl; Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
    procedure SettingsChanged(const Group: string; const Changes: TSettingChanges);
    procedure OpenChosen(Item: TMenuItem);
    procedure SaveAsChosen(Item: TMenuItem);
    procedure NextChosen(Item: TMenuItem);
    procedure PreviousChosen(Item: TMenuItem);
    procedure PropertiesChosen(Item: TMenuItem);
    procedure ExitChosen(Item: TMenuItem);
    procedure CopyChosen(Item: TMenuItem);
    procedure ZoomInChosen(Item: TMenuItem);
    procedure ZoomOutChosen(Item: TMenuItem);
    procedure ActualSizeChosen(Item: TMenuItem);
    procedure FitChosen(Item: TMenuItem);
    procedure FullScreenChosen(Item: TMenuItem);
    procedure ToolBarChosen(Item: TMenuItem);
    procedure StatusBarChosen(Item: TMenuItem);
    procedure ColorManagementChosen(Item: TMenuItem);
    procedure RotateRightChosen(Item: TMenuItem);
    procedure RotateLeftChosen(Item: TMenuItem);
    procedure FlipHorizontallyChosen(Item: TMenuItem);
    procedure FlipVerticallyChosen(Item: TMenuItem);
    procedure PlayChosen(Item: TMenuItem);
    procedure NextFrameChosen(Item: TMenuItem);
    procedure PreviousFrameChosen(Item: TMenuItem);
    procedure AboutChosen(Item: TMenuItem);
    procedure ToolOpen(Sender: TControl);
    procedure ToolPrevious(Sender: TControl);
    procedure ToolNext(Sender: TControl);
    procedure ToolZoomIn(Sender: TControl);
    procedure ToolZoomOut(Sender: TControl);
    procedure ToolActualSize(Sender: TControl);
    procedure ToolFit(Sender: TControl);
    procedure ToolRotateLeft(Sender: TControl);
    procedure ToolRotateRight(Sender: TControl);
    procedure ToolPlay(Sender: TControl);
  protected
    procedure Resized; override;
    procedure KeyDown(Code, Character, Modifiers: LongWord); override;
    procedure CloseRequested; override;
  public
    constructor Create;
    destructor Destroy; override;
    { Shows the image in Path; False (and a message box) if it cannot be
      read. }
    function OpenImage(const Path: string): Boolean;
    property Path: string read FPath;
    property View: TImageView read FView;
  end;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Windowing.Windows,
  Windowing.Clipboard,
  Windowing.SettingsChanges,
  Windowing.Connection,
  Drawing.Rectangles,
  Image.Errors,
  Image.Frames,
  Image.Files,
  Controls.Keys,
  Controls.LayoutRules,
  Controls.SplitRules,
  Controls.FileLists,
  Controls.FileDialog,
  Controls.FileNames,
  Controls.MessageBoxes,
  Controls.ImageClipboard,
  ImageViewer.ViewGeometry,
  ImageViewer.FolderImages,
  ImageViewer.Saving,
  ImageViewer.Settings,
  ImageViewer.Output;

const
  ProgramName = 'Image Viewer';
  OpenFilter = '*.png;*.jpg;*.jpeg;*.gif;*.bmp;*.ico;*.cur;*.tif;*.tiff;*.webp;*.jxl;*.apng;*.dib';
  NoKey = 0;
  { Logical units. }
  WindowWidth = 760;
  WindowHeight = 540;
  SizePanelWidth = 130;
  ZoomPanelWidth = 70;
  FramePanelWidth = 110;
  ToolButtonWidth = 64;
  { Key codes Controls.Keys does not name. }
  KeyR = $13;
  KeyDigit0 = $0B;
  KeyF11 = $57;
  OnOff: array[Boolean] of string = ('off', 'on');

constructor TImageViewerWindow.Create;
var
  Settings: TImageViewerSettings;
begin
  inherited Create(ProgramName, 100, 60, WindowWidth, WindowHeight);
  FFolderImages := TStringList.Create;
  FTurn := NoTurn;
  Settings := RememberedSettings;
  FColorManagement := Settings.ColorManagement;
  BuildMenus;
  BuildToolBar;
  FStatusBar := TStatusBar.Create(Root);
  BuildPanels;
  FSplit.SplitterDistance := WindowWidth - Settings.PropertiesWidth;
  SetPropertiesShown(Settings.PropertiesShown);
  FToolBar.Visible := Settings.ToolBarShown;
  FToolBarItem.Checked := Settings.ToolBarShown;
  FStatusBar.Visible := Settings.StatusBarShown;
  FStatusBarItem.Checked := Settings.StatusBarShown;
  FColorItem.Checked := FColorManagement;
  Root.OnDragOver := @RootDragOver;
  Root.OnDragDrop := @RootDragDrop;
  PlaceStatusPanels;
  UpdateTitle;
  UpdateAnimationCommands;
  ShowStatus;
  FocusControl(FView);
  SubscribeToSettings(ImageViewerSettingsGroup, @SettingsChanged);
  Say(Format('settings colour-management %s, properties %s, toolbar %s, status-bar %s',
    [OnOff[Settings.ColorManagement], OnOff[Settings.PropertiesShown], OnOff[Settings.ToolBarShown],
    OnOff[Settings.StatusBarShown]]));
end;

destructor TImageViewerWindow.Destroy;
begin
  UnsubscribeFromSettings(@SettingsChanged);
  FFolderImages.Free;
  inherited Destroy;
end;

{ --- Building ------------------------------------------------------------------------- }

function TImageViewerWindow.AddItem(Menu: TMenuItem; const Text: string; Handler: TMenuItemEvent;
  const Shortcut: string; Code, Modifiers: LongWord): TMenuItem;
begin
  Result := Menu.Add(Text, Handler, Shortcut);
  if Code <> NoKey then
    AddItemAccelerator(Self, Result, Code, Modifiers);
end;

procedure TImageViewerWindow.BuildMenus;
begin
  FMenuBar := TMenuBar.Create(Root);
  BuildFileAndEditMenus;
  BuildViewMenu;
  BuildImageAndAnimationMenus;
end;

procedure TImageViewerWindow.BuildFileAndEditMenus;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&File');
  AddItem(Menu, '&Open...', @OpenChosen, 'Ctrl+O', KeyO, ModifierControl);
  AddItem(Menu, 'Save &As...', @SaveAsChosen, 'Ctrl+S', KeyS, ModifierControl);
  Menu.AddSeparator;
  AddItem(Menu, '&Next', @NextChosen, 'Right', NoKey, 0);
  AddItem(Menu, '&Previous', @PreviousChosen, 'Left', NoKey, 0);
  Menu.AddSeparator;
  FPropertiesItem := AddItem(Menu, 'P&roperties', @PropertiesChosen, 'Alt+Enter', KeyEnter, ModifierAlt);
  Menu.AddSeparator;
  AddItem(Menu, 'E&xit', @ExitChosen, '', NoKey, 0);
  Menu := FMenuBar.Menu.Add('&Edit');
  AddItem(Menu, '&Copy', @CopyChosen, 'Ctrl+C', KeyC, ModifierControl);
end;

procedure TImageViewerWindow.BuildViewMenu;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&View');
  AddItem(Menu, 'Zoom &In', @ZoomInChosen, '+', NoKey, 0);
  AddItem(Menu, 'Zoom &Out', @ZoomOutChosen, '-', NoKey, 0);
  AddItem(Menu, '&Actual Size', @ActualSizeChosen, 'Ctrl+0', KeyDigit0, ModifierControl);
  AddItem(Menu, '&Fit to Window', @FitChosen, 'Ctrl+F', KeyF, ModifierControl);
  Menu.AddSeparator;
  FFullScreenItem := AddItem(Menu, 'F&ull Screen', @FullScreenChosen, 'F11', KeyF11, 0);
  FToolBarItem := AddItem(Menu, '&Toolbar', @ToolBarChosen, '', NoKey, 0);
  FStatusBarItem := AddItem(Menu, '&Status Bar', @StatusBarChosen, '', NoKey, 0);
  Menu.AddSeparator;
  FColorItem := AddItem(Menu, '&Colour Management', @ColorManagementChosen, '', NoKey, 0);
end;

procedure TImageViewerWindow.BuildImageAndAnimationMenus;
var
  Menu: TMenuItem;
begin
  Menu := FMenuBar.Menu.Add('&Image');
  AddItem(Menu, 'Rotate &Right', @RotateRightChosen, 'Ctrl+R', KeyR, ModifierControl);
  AddItem(Menu, 'Rotate &Left', @RotateLeftChosen, 'Ctrl+L', KeyL, ModifierControl);
  Menu.AddSeparator;
  AddItem(Menu, 'Flip &Horizontally', @FlipHorizontallyChosen, '', NoKey, 0);
  AddItem(Menu, 'Flip &Vertically', @FlipVerticallyChosen, '', NoKey, 0);
  Menu := FMenuBar.Menu.Add('A&nimation');
  FPlayItem := AddItem(Menu, '&Play/Pause', @PlayChosen, 'Space', NoKey, 0);
  FNextFrameItem := AddItem(Menu, '&Next Frame', @NextFrameChosen, '.', NoKey, 0);
  FPreviousFrameItem := AddItem(Menu, 'P&revious Frame', @PreviousFrameChosen, ',', NoKey, 0);
  Menu := FMenuBar.Menu.Add('&Help');
  AddItem(Menu, '&About Image Viewer', @AboutChosen, '', NoKey, 0);
end;

procedure TImageViewerWindow.BuildToolBar;
begin
  FToolBar := TToolBar.Create(Root);
  FToolBar.AddButton('Open', ToolButtonWidth, @ToolOpen);
  FToolBar.AddSeparator;
  FToolBar.AddButton('Previous', ToolButtonWidth, @ToolPrevious);
  FToolBar.AddButton('Next', ToolButtonWidth, @ToolNext);
  FToolBar.AddSeparator;
  FToolBar.AddButton('Zoom in', ToolButtonWidth, @ToolZoomIn);
  FToolBar.AddButton('Zoom out', ToolButtonWidth, @ToolZoomOut);
  FToolBar.AddButton('100%', ToolButtonWidth, @ToolActualSize);
  FToolBar.AddButton('Fit', ToolButtonWidth, @ToolFit);
  FToolBar.AddSeparator;
  FToolBar.AddButton('Rotate left', ToolButtonWidth + 16, @ToolRotateLeft);
  FToolBar.AddButton('Rotate right', ToolButtonWidth + 16, @ToolRotateRight);
  FToolBar.AddSeparator;
  FPlayButton := FToolBar.AddButton('Play', ToolButtonWidth, @ToolPlay);
  FPlayButton.IsToggle := True;
end;

procedure TImageViewerWindow.BuildPanels;
begin
  FSplit := TSplitContainer.Create(Root);
  FSplit.Align := AlignClient;
  FSplit.FixedPanel := FixedPanel2;
  FSplit.Panel1MinSize := 200;
  FSplit.Panel2MinSize := 120;
  FSplit.OnSplitterMoved := @SplitterMoved;
  FView := TImageView.Create(FSplit.Panel1);
  FView.Align := AlignClient;
  FView.OnZoomChanged := @ZoomChanged;
  FView.OnNavigate := @Navigate;
  FProperties := TListView.Create(FSplit.Panel2);
  FProperties.Align := AlignClient;
  FProperties.AddColumn('Property', 110);
  FProperties.AddColumn('Value', 240);
end;

{ --- State ------------------------------------------------------------------------------ }

function TImageViewerWindow.HasImage: Boolean;
begin
  Result := FView.Picture.Image <> nil;
end;

function TImageViewerWindow.IsAnimation: Boolean;
begin
  Result := FView.Picture.FrameCount > 1;
end;

function TImageViewerWindow.StartFolder: string;
begin
  if FPath <> '' then
    Exit(ExtractFileDir(FPath));
  Result := GetCurrentDir;
  if Result = '' then
    Result := '/';
end;

procedure TImageViewerWindow.UpdateTitle;
begin
  if FPath = '' then
    Title := ProgramName
  else
    Title := ExtractFileName(FPath) + ' - ' + ProgramName;
end;

procedure TImageViewerWindow.PlaceStatusPanels;
var
  Rest: LongInt;
begin
  Rest := ClientWidth - SizePanelWidth - ZoomPanelWidth - FramePanelWidth;
  if Rest < 40 then
    Rest := 40;
  FStatusBar.SetPanels([Rest, SizePanelWidth, ZoomPanelWidth, FramePanelWidth]);
end;

procedure TImageViewerWindow.Resized;
begin
  inherited Resized;
  if FStatusBar <> nil then
    PlaceStatusPanels;
end;

procedure TImageViewerWindow.ShowStatus;
var
  Picture: TImage;
begin
  if not HasImage then
  begin
    FStatusBar.PanelText[0] := ' Open an image (Ctrl+O), or drop one here';
    FStatusBar.PanelText[1] := '';
    FStatusBar.PanelText[2] := '';
    FStatusBar.PanelText[3] := '';
    Exit;
  end;
  Picture := FView.Picture.Image;
  FStatusBar.PanelText[0] := ' ' + ExtractFileName(FPath) + '  (' + IntToStr(FFolderImages.IndexOf(
    ExtractFileName(FPath)) + 1) + ' of ' + IntToStr(FFolderImages.Count) + ')';
  FStatusBar.PanelText[1] := ' ' + IntToStr(Picture.Width) + ' x ' + IntToStr(Picture.Height);
  FStatusBar.PanelText[2] := ' ' + ZoomPercentText(FView.Zoom);
  if IsAnimation then
    FStatusBar.PanelText[3] := ' Frame ' + IntToStr(FView.Picture.FrameIndex + 1) + ' of ' +
      IntToStr(FView.Picture.FrameCount)
  else
    FStatusBar.PanelText[3] := '';
end;

procedure TImageViewerWindow.ShowProperties;
var
  Rows: TImageProperties;
  Index: LongInt;
begin
  FProperties.Clear;
  if not HasImage then
    Exit;
  Rows := DescribeImage(FView.Picture.Image, FPath, FFileSize, FColorHandling);
  for Index := 0 to High(Rows) do
    FProperties.AddRow([Rows[Index].Name, Rows[Index].Value]);
end;

procedure TImageViewerWindow.UpdateAnimationCommands;
begin
  FPlayItem.Enabled := IsAnimation;
  FNextFrameItem.Enabled := IsAnimation;
  FPreviousFrameItem.Enabled := IsAnimation;
  FPlayButton.Enabled := IsAnimation;
  FPlayButton.Down := IsAnimation and FView.Picture.Playing;
end;

{ --- Opening ----------------------------------------------------------------------------- }

function FileSizeOf(const Path: string): Int64;
var
  Search: TSearchRec;
begin
  Result := -1;
  if FindFirst(Path, faAnyFile, Search) = 0 then
  begin
    Result := Search.Size;
    FindClose(Search);
  end;
end;

function TImageViewerWindow.OpenImage(const Path: string): Boolean;
var
  FullPath: string;
  Loaded: TImage;
  Reason: TImageErrorReason;
begin
  FullPath := CombinePath(StartFolder, Path);
  Loaded := nil;
  try
    Result := TryLoadImage(FullPath, Loaded, Reason, [ImageLoadApplyOrientation]);
  except
    on Exception do
    begin
      Result := False;
      Reason := ImageErrorMalformed;
    end;
  end;
  if not Result then
  begin
    Loaded.Free;
    Say('error ' + FullPath + ': ' + ImageErrorReasonText(Reason));
    ShowMessageBox(ProgramName, 'Cannot open ' + FullPath + ':'#10 + ImageErrorReasonText(Reason), MessageOk,
      SignError, Self);
    Exit;
  end;
  FColorHandling := ColorHandlingOff;
  if FColorManagement then
    try
      FColorHandling := ColorHandlingOf(Loaded.ConvertToSrgb);
    except
      on Exception do
        FColorHandling := ColorHandlingUnsupported;
    end;
  { The loader turns stills as their EXIF says; an animation is turned
    by the view. }
  FTurn := NoTurn;
  if Loaded is TAnimatedImage then
    FTurn := TurnOfExif(OrientationToExif(Loaded.Orientation));
  FPath := FullPath;
  FFileSize := FileSizeOf(FullPath);
  ListFolderImages(ExtractFileDir(FullPath), FFolderImages);
  FView.Picture.TakeImage(Loaded);
  ApplyTurn;
  FView.FitToWindow;
  UpdateTitle;
  ShowProperties;
  UpdateAnimationCommands;
  ShowStatus;
  Say(Format('opened %s %s %d x %d, %d frames, colour %s', [FullPath, Loaded.SourceFormatName, Loaded.Width,
    Loaded.Height, FView.Picture.FrameCount, ColorHandlingWords[FColorHandling]]));
end;

procedure TImageViewerWindow.Navigate(Step: LongInt);
var
  Name: string;
  Folder: string;
begin
  if FPath = '' then
    Exit;
  Folder := ExtractFileDir(FPath);
  ListFolderImages(Folder, FFolderImages);
  Name := NeighbourName(FFolderImages, ExtractFileName(FPath), Step);
  if (Name = '') or (Name = ExtractFileName(FPath)) then
    Exit;
  OpenImage(IncludeTrailingPathDelimiter(Folder) + Name);
end;

{ --- Turning, zoom, animation ---------------------------------------------------------- }

procedure TImageViewerWindow.ApplyTurn;
begin
  FView.Picture.Orientation := OrientationFromExif(ExifOrientationOf(FTurn));
end;

procedure TImageViewerWindow.ZoomChanged(Sender: TControl);
begin
  ShowStatus;
  Say('zoom ' + ZoomPercentText(FView.Zoom));
end;

procedure TImageViewerWindow.TogglePlaying;
begin
  if not IsAnimation then
    Exit;
  if FView.Picture.Playing then
    FView.Picture.Stop
  else
    FView.Picture.Play;
  UpdateAnimationCommands;
  ShowStatus;
  Say('playing ' + OnOff[FView.Picture.Playing]);
end;

procedure TImageViewerWindow.StepFrame(Step: LongInt);
var
  Count: LongInt;
begin
  if not IsAnimation then
    Exit;
  Count := FView.Picture.FrameCount;
  FView.Picture.ShowFrame(((FView.Picture.FrameIndex + Step) mod Count + Count) mod Count);
  UpdateAnimationCommands;
  ShowStatus;
  Say('frame ' + IntToStr(FView.Picture.FrameIndex + 1));
end;

procedure TImageViewerWindow.SetPropertiesShown(Shown: Boolean);
begin
  FSplit.Panel2Collapsed := not Shown;
  FPropertiesItem.Checked := Shown;
end;

procedure TImageViewerWindow.SetFullScreen(Value: Boolean);
var
  Settings: TImageViewerSettings;
begin
  if FFullScreen = Value then
    Exit;
  FFullScreen := Value;
  FFullScreenItem.Checked := Value;
  Settings := RememberedSettings;
  FMenuBar.Visible := not Value;
  FToolBar.Visible := not Value and Settings.ToolBarShown;
  FStatusBar.Visible := not Value and Settings.StatusBarShown;
  FSplit.Panel2Collapsed := Value or not Settings.PropertiesShown;
  if Value then
    Maximize
  else
    Restore;
  FocusControl(FView);
  Say('full-screen ' + OnOff[Value]);
end;

{ --- Settings ---------------------------------------------------------------------------- }

procedure TImageViewerWindow.ApplySettings;
var
  Settings: TImageViewerSettings;
begin
  Settings := RememberedSettings;
  if not FFullScreen then
  begin
    FToolBar.Visible := Settings.ToolBarShown;
    FStatusBar.Visible := Settings.StatusBarShown;
    SetPropertiesShown(Settings.PropertiesShown);
  end;
  FToolBarItem.Checked := Settings.ToolBarShown;
  FStatusBarItem.Checked := Settings.StatusBarShown;
  FColorItem.Checked := Settings.ColorManagement;
  if Settings.ColorManagement <> FColorManagement then
  begin
    FColorManagement := Settings.ColorManagement;
    if FPath <> '' then
      OpenImage(FPath);
  end;
end;

procedure TImageViewerWindow.SettingsChanged(const Group: string; const Changes: TSettingChanges);
begin
  ApplySettings;
end;

procedure TImageViewerWindow.SplitterMoved(Sender: TControl);
begin
  RememberPropertiesWidth(Unscaled(RectangleWidth(FSplit.Panel2.PixelBounds)));
end;

{ --- Dropped files -------------------------------------------------------------------------- }

procedure TImageViewerWindow.RootDragOver(Sender: TControl; Data: TDragData; X, Y: LongInt; Modifiers: LongWord;
  var Effect: TDropEffect);
begin
  if Data.Format = DragFormatFileList then
    Effect := DropCopy;
end;

procedure TImageViewerWindow.RootDragDrop(Sender: TControl; Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
var
  Paths: TStringList;
  Action: TFileListAction;
begin
  Paths := TStringList.Create;
  try
    if DecodeFileList(Data.Text, Action, Paths) and (Paths.Count > 0) then
    begin
      Say('dropped ' + Paths[0]);
      OpenImage(Paths[0]);
    end;
  finally
    Paths.Free;
  end;
end;

{ --- Menu commands ----------------------------------------------------------------------- }

procedure TImageViewerWindow.OpenChosen(Item: TMenuItem);
var
  Chosen: string;
begin
  if ChooseFileToOpen('Open', StartFolder, OpenFilter, Chosen) then
    OpenImage(Chosen);
end;

procedure TImageViewerWindow.SaveAsChosen(Item: TMenuItem);
var
  Saved: string;
begin
  if not HasImage then
    Exit;
  SaveImageAs(Self, FView.Picture.Image, FView.Picture.CurrentPicture, not IsNoTurn(FTurn), StartFolder,
    ChangeFileExt(ExtractFileName(FPath), '.png'), Saved);
end;

procedure TImageViewerWindow.NextChosen(Item: TMenuItem);
begin
  Navigate(1);
end;

procedure TImageViewerWindow.PreviousChosen(Item: TMenuItem);
begin
  Navigate(-1);
end;

procedure TImageViewerWindow.PropertiesChosen(Item: TMenuItem);
var
  Shown: Boolean;
begin
  Shown := FSplit.Panel2Collapsed;
  SetPropertiesShown(Shown);
  RememberPropertiesShown(Shown);
  Say('properties ' + OnOff[Shown]);
end;

procedure TImageViewerWindow.ExitChosen(Item: TMenuItem);
begin
  CloseRequested;
end;

procedure TImageViewerWindow.CopyChosen(Item: TMenuItem);
var
  Shown: TImage;
begin
  Shown := FView.Picture.CurrentPicture;
  if Shown = nil then
    Exit;
  CopyImageToClipboard(Shown.Clone);
  Say(Format('copied %d x %d', [Shown.Width, Shown.Height]));
end;

procedure TImageViewerWindow.ZoomInChosen(Item: TMenuItem);
begin
  FView.ZoomIn;
end;

procedure TImageViewerWindow.ZoomOutChosen(Item: TMenuItem);
begin
  FView.ZoomOut;
end;

procedure TImageViewerWindow.ActualSizeChosen(Item: TMenuItem);
begin
  FView.ActualSize;
end;

procedure TImageViewerWindow.FitChosen(Item: TMenuItem);
begin
  FView.FitToWindow;
end;

procedure TImageViewerWindow.FullScreenChosen(Item: TMenuItem);
begin
  SetFullScreen(not FFullScreen);
end;

procedure TImageViewerWindow.ToolBarChosen(Item: TMenuItem);
begin
  FToolBar.Visible := not FToolBar.Visible;
  FToolBarItem.Checked := FToolBar.Visible;
  RememberToolBarShown(FToolBar.Visible);
end;

procedure TImageViewerWindow.StatusBarChosen(Item: TMenuItem);
begin
  FStatusBar.Visible := not FStatusBar.Visible;
  FStatusBarItem.Checked := FStatusBar.Visible;
  RememberStatusBarShown(FStatusBar.Visible);
end;

procedure TImageViewerWindow.ColorManagementChosen(Item: TMenuItem);
begin
  FColorManagement := not FColorManagement;
  FColorItem.Checked := FColorManagement;
  RememberColorManagement(FColorManagement);
  Say('colour-management ' + OnOff[FColorManagement]);
  if FPath <> '' then
    OpenImage(FPath);
end;

procedure TImageViewerWindow.RotateRightChosen(Item: TMenuItem);
begin
  FTurn := TurnedClockwise(FTurn);
  ApplyTurn;
  Say('orientation ' + IntToStr(ExifOrientationOf(FTurn)));
end;

procedure TImageViewerWindow.RotateLeftChosen(Item: TMenuItem);
begin
  FTurn := TurnedAnticlockwise(FTurn);
  ApplyTurn;
  Say('orientation ' + IntToStr(ExifOrientationOf(FTurn)));
end;

procedure TImageViewerWindow.FlipHorizontallyChosen(Item: TMenuItem);
begin
  FTurn := FlippedHorizontally(FTurn);
  ApplyTurn;
  Say('orientation ' + IntToStr(ExifOrientationOf(FTurn)));
end;

procedure TImageViewerWindow.FlipVerticallyChosen(Item: TMenuItem);
begin
  FTurn := FlippedVertically(FTurn);
  ApplyTurn;
  Say('orientation ' + IntToStr(ExifOrientationOf(FTurn)));
end;

procedure TImageViewerWindow.PlayChosen(Item: TMenuItem);
begin
  TogglePlaying;
end;

procedure TImageViewerWindow.NextFrameChosen(Item: TMenuItem);
begin
  StepFrame(1);
end;

procedure TImageViewerWindow.PreviousFrameChosen(Item: TMenuItem);
begin
  StepFrame(-1);
end;

procedure TImageViewerWindow.AboutChosen(Item: TMenuItem);
begin
  ShowMessageBox('About Image Viewer', 'Image Viewer'#10'Shows BMP, ICO, GIF, JPEG, PNG, APNG, TIFF, WebP and ' +
    'JPEG XL pictures on FreePascalOS.', MessageOk, SignInformation, Self);
end;

procedure TImageViewerWindow.ToolOpen(Sender: TControl);
begin
  OpenChosen(nil);
end;

procedure TImageViewerWindow.ToolPrevious(Sender: TControl);
begin
  Navigate(-1);
end;

procedure TImageViewerWindow.ToolNext(Sender: TControl);
begin
  Navigate(1);
end;

procedure TImageViewerWindow.ToolZoomIn(Sender: TControl);
begin
  FView.ZoomIn;
end;

procedure TImageViewerWindow.ToolZoomOut(Sender: TControl);
begin
  FView.ZoomOut;
end;

procedure TImageViewerWindow.ToolActualSize(Sender: TControl);
begin
  FView.ActualSize;
end;

procedure TImageViewerWindow.ToolFit(Sender: TControl);
begin
  FView.FitToWindow;
end;

procedure TImageViewerWindow.ToolRotateLeft(Sender: TControl);
begin
  RotateLeftChosen(nil);
end;

procedure TImageViewerWindow.ToolRotateRight(Sender: TControl);
begin
  RotateRightChosen(nil);
end;

procedure TImageViewerWindow.ToolPlay(Sender: TControl);
begin
  TogglePlaying;
end;

{ --- Keys ---------------------------------------------------------------------------------- }

{ Single characters for the view's commands, wherever the focus is but
  in the properties list (which finds rows by typing). }
procedure TImageViewerWindow.KeyDown(Code, Character, Modifiers: LongWord);
var
  Handled: Boolean;
begin
  Handled := False;
  if (Popup = nil) and not ((MenuBar <> nil) and MenuBar.InMenuMode) and
     ((Modifiers and (ModifierControl or ModifierAlt)) = 0) and (FocusedControl <> FProperties) then
  begin
    Handled := True;
    if (Code = KeyEscape) and FFullScreen then
      SetFullScreen(False)
    else if (Character = Ord('+')) or (Character = Ord('=')) then
      FView.ZoomIn
    else if Character = Ord('-') then
      FView.ZoomOut
    else if Character = Ord(' ') then
      TogglePlaying
    else if Character = Ord('.') then
      StepFrame(1)
    else if Character = Ord(',') then
      StepFrame(-1)
    else
      Handled := False;
  end;
  if not Handled then
    inherited KeyDown(Code, Character, Modifiers);
end;

procedure TImageViewerWindow.CloseRequested;
begin
  FlushClipboard;
  Say('exit');
  QuitMessageLoop(0);
end;

end.
