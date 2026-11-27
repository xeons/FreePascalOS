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
  The picture being painted and its history: the image, the undo steps
  of every edit, and whether it has changes since it was opened or
  saved.

  An edit of part of the picture is recorded after it is made, from a
  copy of the picture taken before it (RecordAreaChange: the part that
  changed is cut out of the copy and of the picture as it is now). An
  edit that makes a new picture (another size) hands it over
  (ReplaceImage) and the old one is kept for undo. Undo and Redo put a
  step back and say what changed: a rectangle, or the whole picture
  (its size may be another).
}
unit Paint.Document;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Rectangles,
  Image.Model,
  Paint.UndoHistory;

type
  TPaintDocument = class
  private
    FImage: TImage;
    FHistory: TUndoHistory;
    FSavedVersion: QWord;
    function ApplyStep(Step: TUndoStep; Forward: Boolean; out Area: TRectangle): Boolean;
  public
    { A document of Image (taken), unchanged. }
    constructor Create(AImage: TImage);
    destructor Destroy; override;
    { Another picture (taken: new or opened), with no history, unchanged. }
    procedure Reset(AImage: TImage);
    { Records the edit of Area just made; Before is the picture as it was
      before (the same size; not taken). Nothing if Area (cut to the
      picture) is empty. }
    procedure RecordAreaChange(Before: TImage; const Area: TRectangle; const Description: string);
    { The picture becomes NewImage (taken); the old one goes into the
      history. }
    procedure ReplaceImage(NewImage: TImage; const Description: string);
    { Undoes (or redoes) a step: True if there was one; Area is what
      changed, or empty when it was the whole picture. }
    function Undo(out Area: TRectangle): Boolean;
    function Redo(out Area: TRectangle): Boolean;
    function CanUndo: Boolean;
    function CanRedo: Boolean;
    { It is as it was when last saved (or opened). }
    procedure MarkSaved;
    function Modified: Boolean;
    property Image: TImage read FImage;
    property History: TUndoHistory read FHistory;
  end;

implementation

uses
  Image.Areas;

constructor TPaintDocument.Create(AImage: TImage);
begin
  inherited Create;
  FHistory := TUndoHistory.Create;
  FImage := AImage;
  FSavedVersion := FHistory.CurrentVersion;
end;

destructor TPaintDocument.Destroy;
begin
  FHistory.Free;
  FImage.Free;
  inherited Destroy;
end;

procedure TPaintDocument.Reset(AImage: TImage);
begin
  FHistory.Clear;
  if AImage <> FImage then
    FImage.Free;
  FImage := AImage;
  FSavedVersion := FHistory.CurrentVersion;
end;

procedure TPaintDocument.RecordAreaChange(Before: TImage; const Area: TRectangle; const Description: string);
var
  Inside: TRectangle;
begin
  if (Before = nil) or (Before.Width <> FImage.Width) or (Before.Height <> FImage.Height) then
    Exit;
  Inside := ClipToImage(FImage, Area);
  if RectangleIsEmpty(Inside) then
    Exit;
  FHistory.Add(TUndoStep.CreateArea(Inside, CopyImageArea(Before, Inside), CopyImageArea(FImage, Inside),
    Description));
end;

procedure TPaintDocument.ReplaceImage(NewImage: TImage; const Description: string);
begin
  if NewImage = FImage then
    Exit;
  FHistory.Add(TUndoStep.CreateWholeImage(FImage, NewImage.Clone, Description));
  FImage := NewImage;
end;

function TPaintDocument.ApplyStep(Step: TUndoStep; Forward: Boolean; out Area: TRectangle): Boolean;
var
  Source: TImage;
begin
  Area := MakeRectangle(0, 0, 0, 0);
  if Step = nil then
    Exit(False);
  if Forward then
    Source := Step.After
  else
    Source := Step.Before;
  case Step.Kind of
    UndoStepArea:
      begin
        PutImage(FImage, Source, Step.Area.Left, Step.Area.Top);
        Area := Step.Area;
      end;
    UndoStepWholeImage:
      begin
        FImage.Free;
        FImage := Source.Clone;
      end;
  end;
  Result := True;
end;

function TPaintDocument.Undo(out Area: TRectangle): Boolean;
begin
  Result := ApplyStep(FHistory.TakeUndo, False, Area);
end;

function TPaintDocument.Redo(out Area: TRectangle): Boolean;
begin
  Result := ApplyStep(FHistory.TakeRedo, True, Area);
end;

function TPaintDocument.CanUndo: Boolean;
begin
  Result := FHistory.CanUndo;
end;

function TPaintDocument.CanRedo: Boolean;
begin
  Result := FHistory.CanRedo;
end;

procedure TPaintDocument.MarkSaved;
begin
  FSavedVersion := FHistory.CurrentVersion;
end;

function TPaintDocument.Modified: Boolean;
begin
  Result := FHistory.CurrentVersion <> FSavedVersion;
end;

end.
