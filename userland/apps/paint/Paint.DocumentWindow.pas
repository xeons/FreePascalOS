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
  Paint's window as far as its file goes, and how it is laid out.

  The layout is docking and the layout panels, no positions: the menu
  bar along the top, the status bar and the colour box (Paint.ColorBox)
  along the bottom, and between them a split container with the tool
  box (Paint.ToolBox) in its first panel, kept at its width when the
  window is resized, and the view of the picture (Paint.CanvasView) in
  the second; the splitter between them moves with the mouse or the
  keyboard.

  The file: the picture being painted came from a file or is new
  ("Untitled"); the title shows its name. New asks for a size, Open and
  Save As use the file dialog (opening any picture libimage reads,
  saving in the format the name's extension says: PNG when it has
  none; JPEG asks for a quality), and a file dragged onto the window
  (from the file manager) is opened. Whatever would throw changes away
  (New, Open, a drop, closing) asks first whether to save them, as
  Notepad does. Errors reading or writing are told in a message box.
}
unit Paint.DocumentWindow;

{$mode objfpc}
{$H+}

interface

uses
  Controls.Base,
  Controls.Window,
  Controls.DragData,
  Controls.SplitContainer,
  Controls.StatusBar,
  Image.Model,
  Paint.Session,
  Paint.CanvasView,
  Paint.ToolBox,
  Paint.ColorBox;

type
  TDocumentWindow = class(TControlWindow)
  private
    FPath: string;
    FJpegQuality: LongInt;
    function StartFolder: string;
    function WriteDocument(const APath: string): Boolean;
    procedure RootDragOver(Sender: TControl; Data: TDragData; X, Y: LongInt; Modifiers: LongWord;
      var Effect: TDropEffect);
    procedure RootDragDrop(Sender: TControl; Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
  protected
    FSession: TPaintSession;
    FSplit: TSplitContainer;
    FToolBox: TToolBox;
    FView: TCanvasView;
    FColorBox: TColorBox;
    FStatusBar: TStatusBar;
    procedure CloseRequested; override;
    { The document became another (opened, new, saved under a name). }
    procedure DocumentChanged; virtual;
    { Ends whatever a tool has under way and puts down anything
      floating, so the picture is all there (before a save, say). }
    procedure FinishWork; virtual;
    { A new picture took the place of the old one. }
    procedure PictureReplaced; virtual;
  public
    constructor Create;
    destructor Destroy; override;
    { "Untitled", or the file's name. }
    function DocumentName: string;
    procedure UpdateTitle;
    function ConfirmDiscard: Boolean;
    { A new white picture of Width x Height (no question asked). }
    procedure StartNewPicture(Width, Height: LongInt);
    { Asks for a size, then starts a new picture (if the changes may go). }
    procedure NewDocument;
    { Opens APath (no question asked); False if it cannot be read. A
      file that does not exist yet is the name the picture is saved as. }
    function OpenDocument(const APath: string): Boolean;
    procedure ChooseAndOpenDocument;
    function SaveDocument: Boolean;
    function SaveDocumentAs: Boolean;
    procedure ExitIfAllowed;
    property Path: string read FPath;
    property Session: TPaintSession read FSession;
    property JpegQuality: LongInt read FJpegQuality write FJpegQuality;
  end;

implementation

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Files,
  Util.Paths,
  Drawing.Colors,
  Windowing.Windows,
  Controls.MessageBoxes,
  Controls.Dialogs,
  Controls.FileDialog,
  Controls.FileLists,
  Controls.FileNames,
  Controls.SplitRules,
  Image.Codecs,
  Paint.FileFormats,
  Paint.PictureFiles,
  Paint.ImageSizeDialog,
  Paint.QualityDialog,
  Paint.Settings,
  Paint.Output;

const
  ProgramName = 'Paint';
  { Logical units. }
  WindowLeft = 60;
  WindowTop = 40;
  WindowWidth = 820;
  WindowHeight = 600;
  ToolBoxWidth = 104;
  SmallestToolBoxWidth = 60;
  SmallestViewWidth = 120;

function NewWhitePicture(Width, Height: LongInt): TImage;
begin
  Result := TImage.Create(Width, Height);
  Result.Fill(ColorWhite);
end;

constructor TDocumentWindow.Create;
var
  Preferences: TPaintPreferences;
begin
  inherited Create(ProgramName, WindowLeft, WindowTop, WindowWidth, WindowHeight);
  IconName := 'app-paint';
  Preferences := RememberedPreferences;
  FJpegQuality := Preferences.JpegQuality;
  FSession := TPaintSession.Create(NewWhitePicture(Preferences.NewWidth, Preferences.NewHeight));
  FStatusBar := TStatusBar.Create(Root);
  FColorBox := TColorBox.Create(Root);
  FColorBox.Align := AlignBottom;
  FColorBox.AutoSize := True;
  FColorBox.DockOrder := 1;
  FSplit := TSplitContainer.Create(Root);
  FSplit.Align := AlignClient;
  FSplit.FixedPanel := FixedPanel1;
  FSplit.Panel1MinSize := SmallestToolBoxWidth;
  FSplit.Panel2MinSize := SmallestViewWidth;
  FSplit.SplitterDistance := ToolBoxWidth;
  FToolBox := TToolBox.Create(FSplit.Panel1);
  FToolBox.Align := AlignClient;
  FView := TCanvasView.Create(FSplit.Panel2);
  FView.Align := AlignClient;
  FView.ShowGrid := Preferences.PixelGrid;
  FStatusBar.Visible := Preferences.StatusBar;
  FToolBox.AttachSession(FSession);
  FColorBox.AttachSession(FSession);
  FView.AttachSession(FSession);
  Root.OnDragOver := @RootDragOver;
  Root.OnDragDrop := @RootDragDrop;
  FocusControl(FView.Area);
end;

destructor TDocumentWindow.Destroy;
begin
  inherited Destroy;
  FSession.Free;
end;

function TDocumentWindow.DocumentName: string;
begin
  if FPath = '' then
    Result := 'Untitled'
  else
    Result := LastPartOf(FPath);
end;

procedure TDocumentWindow.UpdateTitle;
begin
  Title := DocumentName + ' - ' + ProgramName;
  Say('title ' + Title);
end;

procedure TDocumentWindow.DocumentChanged;
begin
  UpdateTitle;
end;

procedure TDocumentWindow.FinishWork;
begin
  FSession.Editor.Deselect;
end;

procedure TDocumentWindow.PictureReplaced;
begin
  FSession.Editor.Forget;
  FSession.WholeImageChanged;
end;

function TDocumentWindow.StartFolder: string;
begin
  if FPath <> '' then
    Exit(ParentFolderOf(FPath));
  if CurrentDirectoryPath(Result) <> ErrorNone then
    Result := '/';
end;

function TDocumentWindow.ConfirmDiscard: Boolean;
var
  Answer: LongInt;
begin
  FinishWork;
  if not FSession.Document.Modified then
    Exit(True);
  Answer := ShowMessageBox(ProgramName, 'The picture in ' + DocumentName + ' has changed.'#10#10 +
    'Do you want to save the changes?', MessageYesNoCancel, SignWarning, Self);
  case Answer of
    ResultYes:
      begin
        Say('answer yes');
        Result := SaveDocument;
      end;
    ResultNo:
      begin
        Say('answer no');
        Result := True;
      end;
  else
    Say('answer cancel');
    Result := False;
  end;
end;

procedure TDocumentWindow.StartNewPicture(Width, Height: LongInt);
begin
  FPath := '';
  FSession.Editor.Forget;
  FSession.Document.Reset(NewWhitePicture(Width, Height));
  PictureReplaced;
  Say('image ' + IntToStr(Width) + ' ' + IntToStr(Height));
  DocumentChanged;
end;

procedure TDocumentWindow.NewDocument;
var
  Width: LongInt;
  Height: LongInt;
begin
  if not ConfirmDiscard then
    Exit;
  Width := FSession.Document.Image.Width;
  Height := FSession.Document.Image.Height;
  if not AskForImageSize(Self, 'New picture', '', Width, Height) then
    Exit;
  RememberNewSize(Width, Height);
  StartNewPicture(Width, Height);
end;

function TDocumentWindow.OpenDocument(const APath: string): Boolean;
var
  FullPath: string;
  Picture: TImage;
  Problem: string;
begin
  FullPath := CombinePath(StartFolder, APath);
  if not PathExists(PChar(FullPath)) then
  begin
    { A new file, made when saved (as Notepad does). }
    FPath := FullPath;
    Say('new ' + FPath);
    DocumentChanged;
    Exit(True);
  end;
  if not ReadPicture(FullPath, Picture, Problem) then
  begin
    ShowMessageBox(ProgramName, 'Cannot open ' + FullPath + ':'#10 + Problem, MessageOk, SignError, Self);
    Exit(False);
  end;
  FPath := FullPath;
  FSession.Editor.Forget;
  FSession.Document.Reset(Picture);
  PictureReplaced;
  Say('opened ' + FPath);
  Say('image ' + IntToStr(Picture.Width) + ' ' + IntToStr(Picture.Height));
  DocumentChanged;
  Result := True;
end;

procedure TDocumentWindow.ChooseAndOpenDocument;
var
  Chosen: string;
begin
  if not ConfirmDiscard then
    Exit;
  if ChooseFileToOpen('Open', StartFolder, OpenFilter, Chosen) then
    OpenDocument(Chosen);
end;

function TDocumentWindow.WriteDocument(const APath: string): Boolean;
var
  Format: TImageFormat;
  Quality: LongInt;
  Problem: string;
begin
  FinishWork;
  Format := SaveFormatForPath(APath);
  if Format = ImageFormatUnknown then
  begin
    ShowMessageBox(ProgramName, 'Paint cannot save ' + LastPartOf(APath) + ' in that format.'#10 +
      'Name it .png, .bmp, .jpg, .gif, .tif or .webp.', MessageOk, SignError, Self);
    Exit(False);
  end;
  Quality := FJpegQuality;
  if FormatIsLossy(Format) then
  begin
    if not AskForJpegQuality(Self, Quality) then
      Exit(False);
    FJpegQuality := Quality;
    RememberJpegQuality(Quality);
  end;
  if not WritePicture(FSession.Document.Image, APath, Format, Quality, Problem) then
  begin
    ShowMessageBox(ProgramName, 'Cannot save ' + APath + ':'#10 + Problem, MessageOk, SignError, Self);
    Exit(False);
  end;
  FPath := APath;
  FSession.Document.MarkSaved;
  Say('saved ' + FPath);
  DocumentChanged;
  Result := True;
end;

function TDocumentWindow.SaveDocument: Boolean;
begin
  if (FPath = '') or (SaveFormatForPath(FPath) = ImageFormatUnknown) then
    Result := SaveDocumentAs
  else
    Result := WriteDocument(FPath);
end;

function TDocumentWindow.SaveDocumentAs: Boolean;
var
  Chosen: string;
  Name: string;
begin
  Name := 'Untitled.png';
  if FPath <> '' then
    Name := LastPartOf(FPath);
  Result := ChooseFileToSave('Save As', StartFolder, SaveFilter, Chosen, Name) and
    WriteDocument(PathWithDefaultExtension(Chosen));
end;

procedure TDocumentWindow.ExitIfAllowed;
begin
  if not ConfirmDiscard then
    Exit;
  Say('exit');
  QuitMessageLoop(0);
end;

procedure TDocumentWindow.CloseRequested;
begin
  ExitIfAllowed;
end;

procedure TDocumentWindow.RootDragOver(Sender: TControl; Data: TDragData; X, Y: LongInt; Modifiers: LongWord;
  var Effect: TDropEffect);
begin
  if Data.Format = DragFormatFileList then
    Effect := DropCopy;
end;

procedure TDocumentWindow.RootDragDrop(Sender: TControl; Data: TDragData; X, Y: LongInt; Effect: TDropEffect);
var
  Paths: TStringList;
  Action: TFileListAction;
begin
  if Data.Format <> DragFormatFileList then
    Exit;
  Paths := TStringList.Create;
  try
    if not DecodeFileList(Data.Text, Action, Paths) or (Paths.Count = 0) then
      Exit;
    Say('dropped ' + Paths[0]);
    if ConfirmDiscard then
      OpenDocument(Paths[0]);
  finally
    Paths.Free;
  end;
end;

end.
