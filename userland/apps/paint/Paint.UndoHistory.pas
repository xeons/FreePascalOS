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
  Undo and redo for pictures, by the part each edit changed.

  A step keeps the pixels of the rectangle an edit changed as they were
  before it and as they are after it (a stroke across a corner keeps
  that corner, not the picture), or, for an edit that changes the whole
  picture's size (a turn, a crop, a resize), the picture before and
  after. Undo puts the before back, redo the after.

  Steps are kept as long as they fit in a memory budget (LimitBytes, 256
  MiB unless set) and number at most MaximumSteps: past either the
  oldest are forgotten, though the newest is always kept, however large.
  A new step forgets everything that could be redone. Every step gets a
  version number, larger than any before it; the version of the step
  that would be undone next says which state the picture is in (0: as
  it started; with nothing left to undo, the newest step forgotten's), so a document compares it with the version it was saved
  at to know whether it has changes.
}
unit Paint.UndoHistory;

{$mode objfpc}
{$H+}

interface

uses
  fgl,
  Drawing.Rectangles,
  Image.Model;

const
  DefaultUndoLimitBytes = 256 * 1024 * 1024;
  MaximumUndoSteps = 1000;

type
  TUndoStepKind = (UndoStepArea, UndoStepWholeImage);

  TUndoStep = class
  private
    FKind: TUndoStepKind;
    FArea: TRectangle;
    FBefore: TImage;
    FAfter: TImage;
    FDescription: string;
    FVersion: QWord;
  public
    { An area step: the pixels of Area before and after (taken). }
    constructor CreateArea(const AArea: TRectangle; ABefore, AAfter: TImage; const ADescription: string);
    { A whole picture step: the pictures before and after (taken). }
    constructor CreateWholeImage(ABefore, AAfter: TImage; const ADescription: string);
    destructor Destroy; override;
    { The memory the step's pixels take. }
    function SizeInBytes: QWord;
    property Kind: TUndoStepKind read FKind;
    property Area: TRectangle read FArea;
    property Before: TImage read FBefore;
    property After: TImage read FAfter;
    property Description: string read FDescription;
    property Version: QWord read FVersion;
  end;

  TUndoStepList = specialize TFPGObjectList<TUndoStep>;

  TUndoHistory = class
  private
    FUndoSteps: TUndoStepList;
    FRedoSteps: TUndoStepList;
    FLimitBytes: QWord;
    FBytesKept: QWord;
    FLastVersion: QWord;
    { The version of the newest step forgotten (0: none). }
    FForgottenVersion: QWord;
    procedure ForgetOldest;
    procedure ClearRedo;
  public
    constructor Create;
    destructor Destroy; override;
    { Adds a step (the history owns it): what could be redone is gone. }
    procedure Add(Step: TUndoStep);
    function CanUndo: Boolean;
    function CanRedo: Boolean;
    { The step Undo would undo (nil if none), and Redo redo. }
    function NextUndo: TUndoStep;
    function NextRedo: TUndoStep;
    { Moves the next step to undo over to the redo side and returns it
      (still the history's), for its Before to be put back; nil if none. }
    function TakeUndo: TUndoStep;
    { The other way: its After to be put back. }
    function TakeRedo: TUndoStep;
    procedure Clear;
    { The version of the step Undo would undo; if none, of the newest
      step forgotten (0: none, the picture is as it started). }
    function CurrentVersion: QWord;
    function UndoCount: LongInt;
    function RedoCount: LongInt;
    property BytesKept: QWord read FBytesKept;
    property LimitBytes: QWord read FLimitBytes write FLimitBytes;
  end;

implementation

function ImageBytes(Image: TImage): QWord;
begin
  if Image = nil then
    Exit(0);
  Result := QWord(Image.Width) * QWord(Image.Height) * SizeOf(LongWord);
end;

constructor TUndoStep.CreateArea(const AArea: TRectangle; ABefore, AAfter: TImage; const ADescription: string);
begin
  inherited Create;
  FKind := UndoStepArea;
  FArea := AArea;
  FBefore := ABefore;
  FAfter := AAfter;
  FDescription := ADescription;
end;

constructor TUndoStep.CreateWholeImage(ABefore, AAfter: TImage; const ADescription: string);
begin
  inherited Create;
  FKind := UndoStepWholeImage;
  FArea := MakeRectangle(0, 0, 0, 0);
  FBefore := ABefore;
  FAfter := AAfter;
  FDescription := ADescription;
end;

destructor TUndoStep.Destroy;
begin
  FBefore.Free;
  FAfter.Free;
  inherited Destroy;
end;

function TUndoStep.SizeInBytes: QWord;
begin
  Result := ImageBytes(FBefore) + ImageBytes(FAfter);
end;

constructor TUndoHistory.Create;
begin
  inherited Create;
  FUndoSteps := TUndoStepList.Create(True);
  FRedoSteps := TUndoStepList.Create(True);
  FLimitBytes := DefaultUndoLimitBytes;
end;

destructor TUndoHistory.Destroy;
begin
  FUndoSteps.Free;
  FRedoSteps.Free;
  inherited Destroy;
end;

procedure TUndoHistory.ForgetOldest;
begin
  Dec(FBytesKept, FUndoSteps[0].SizeInBytes);
  FForgottenVersion := FUndoSteps[0].Version;
  FUndoSteps.Delete(0);
end;

procedure TUndoHistory.ClearRedo;
begin
  while FRedoSteps.Count > 0 do
  begin
    Dec(FBytesKept, FRedoSteps.Last.SizeInBytes);
    FRedoSteps.Delete(FRedoSteps.Count - 1);
  end;
end;

procedure TUndoHistory.Add(Step: TUndoStep);
begin
  ClearRedo;
  Inc(FLastVersion);
  Step.FVersion := FLastVersion;
  FUndoSteps.Add(Step);
  Inc(FBytesKept, Step.SizeInBytes);
  while (FUndoSteps.Count > 1) and ((FBytesKept > FLimitBytes) or (FUndoSteps.Count > MaximumUndoSteps)) do
    ForgetOldest;
end;

function TUndoHistory.CanUndo: Boolean;
begin
  Result := FUndoSteps.Count > 0;
end;

function TUndoHistory.CanRedo: Boolean;
begin
  Result := FRedoSteps.Count > 0;
end;

function TUndoHistory.NextUndo: TUndoStep;
begin
  if FUndoSteps.Count = 0 then
    Exit(nil);
  Result := FUndoSteps.Last;
end;

function TUndoHistory.NextRedo: TUndoStep;
begin
  if FRedoSteps.Count = 0 then
    Exit(nil);
  Result := FRedoSteps.Last;
end;

function TUndoHistory.TakeUndo: TUndoStep;
begin
  if FUndoSteps.Count = 0 then
    Exit(nil);
  Result := FUndoSteps.Extract(FUndoSteps.Last);
  FRedoSteps.Add(Result);
end;

function TUndoHistory.TakeRedo: TUndoStep;
begin
  if FRedoSteps.Count = 0 then
    Exit(nil);
  Result := FRedoSteps.Extract(FRedoSteps.Last);
  FUndoSteps.Add(Result);
end;

procedure TUndoHistory.Clear;
begin
  FUndoSteps.Clear;
  FRedoSteps.Clear;
  FBytesKept := 0;
  FForgottenVersion := 0;
end;

function TUndoHistory.CurrentVersion: QWord;
begin
  if FUndoSteps.Count = 0 then
    Exit(FForgottenVersion);
  Result := FUndoSteps.Last.Version;
end;

function TUndoHistory.UndoCount: LongInt;
begin
  Result := FUndoSteps.Count;
end;

function TUndoHistory.RedoCount: LongInt;
begin
  Result := FRedoSteps.Count;
end;

end.
