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

{ The reference pages: layout tree dumps against the expected ones. }
unit WebLayoutTest.Pages;

{$mode objfpc}
{$H+}

interface

uses
  Web.Dom, Web.Layout.Document;

procedure SetFontDirectory(const Directory: string);
procedure CheckReferencePages(const Directory: string; Update: Boolean);
{ A document parsed from text and its layout at a width. }
function LayoutText(const Html: string; Width: Single; out Document: TDocument): TDocumentLayout;
procedure FreeLayout(Layout: TDocumentLayout; Document: TDocument);
function ReadTextFile(const Path: string): string;

implementation

uses
  SysUtils, Classes, Math, TestChecks, Web.Html.Parser, Web.Text.Fonts, Web.Layout.Dump, Web.Layout.Resources,
  Svg.Fonts;

procedure SetFontDirectory(const Directory: string);
begin
  WebFontDirectory := Directory;
  SvgFontDirectory := Directory;
  ResetWebFontLibrary;
end;

function ReadTextFile(const Path: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  if not FileExists(Path) then
    Exit;
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

procedure WriteTextFile(const Path, Text: string);
var
  Stream: TFileStream;
begin
  Stream := TFileStream.Create(Path, fmCreate);
  try
    if Text <> '' then
      Stream.WriteBuffer(Text[1], Length(Text));
  finally
    Stream.Free;
  end;
end;

function LayoutText(const Html: string; Width: Single; out Document: TDocument): TDocumentLayout;
begin
  Document := ParseHtmlText(Html);
  Result := TDocumentLayout.Create(Document, DocumentResourcesOf(Document));
  Result.SetViewport(Width, 600, 1);
  Result.Update;
end;

procedure FreeLayout(Layout: TDocumentLayout; Document: TDocument);
begin
  Layout.Free;
  FreeDocumentResources(Document);
  Document.Release;
end;

function PageWidth(const Html: string): Single;
var
  Position, Stop: Integer;
begin
  Result := 800;
  Position := Pos('<!-- width=', Html);
  if Position = 0 then
    Exit;
  Inc(Position, Length('<!-- width='));
  Stop := Position;
  while (Stop <= Length(Html)) and (Html[Stop] in ['0'..'9']) do
    Inc(Stop);
  Result := StrToFloatDef(Copy(Html, Position, Stop - Position), 800);
end;

{ The first line where two dumps differ, for the failure message. }
function FirstDifference(const Expected, Actual: string): string;
var
  ExpectedLines, ActualLines: TStringList;
  Index: Integer;
begin
  Result := '';
  ExpectedLines := TStringList.Create;
  ActualLines := TStringList.Create;
  try
    ExpectedLines.Text := Expected;
    ActualLines.Text := Actual;
    for Index := 0 to Max(ExpectedLines.Count, ActualLines.Count) - 1 do
    begin
      if (Index >= ExpectedLines.Count) or (Index >= ActualLines.Count) or
         (ExpectedLines[Index] <> ActualLines[Index]) then
      begin
        Result := 'line ' + IntToStr(Index + 1) + ':' + LineEnding + '  expected: ';
        if Index < ExpectedLines.Count then
          Result := Result + ExpectedLines[Index];
        Result := Result + LineEnding + '  actual:   ';
        if Index < ActualLines.Count then
          Result := Result + ActualLines[Index];
        Exit;
      end;
    end;
  finally
    ExpectedLines.Free;
    ActualLines.Free;
  end;
end;

procedure CheckReferencePages(const Directory: string; Update: Boolean);
var
  Search: TSearchRec;
  Names: TStringList;
  Index: Integer;
  Html, Expected, Actual, ExpectedPath: string;
  Document: TDocument;
  Layout: TDocumentLayout;
begin
  Names := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Directory) + '*.html', 0, Search) = 0 then
    try
      repeat
        Names.Add(Search.Name);
      until FindNext(Search) <> 0;
    finally
      FindClose(Search);
    end;
    Names.Sort;
    Check(Names.Count > 0, 'reference pages found');
    for Index := 0 to Names.Count - 1 do
    begin
      Html := ReadTextFile(IncludeTrailingPathDelimiter(Directory) + Names[Index]);
      Layout := LayoutText(Html, PageWidth(Html), Document);
      try
        Actual := DumpLayoutTree(Layout.Root);
      finally
        FreeLayout(Layout, Document);
      end;
      ExpectedPath := IncludeTrailingPathDelimiter(Directory) + ChangeFileExt(Names[Index], '.txt');
      if Update then
        WriteTextFile(ExpectedPath, Actual);
      Expected := ReadTextFile(ExpectedPath);
      if Expected <> Actual then
        WriteLn(FirstDifference(Expected, Actual));
      Check(Expected = Actual, 'layout of ' + Names[Index]);
    end;
  finally
    Names.Free;
  end;
end;

end.
