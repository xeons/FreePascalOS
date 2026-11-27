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
  Rendering one page from files: parse, supply the resources a loader
  would (style sheets of <link rel=stylesheet>, images of <img> and of
  url() in style, read from beside the page), lay out, dump or paint.
  Shared by webrender and the layout test.
}
unit WebRender.Pages;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils, Classes, Web.Dom, Web.Layout.Document, Web.Layout.Resources;

type
  TRenderOptions = record
    InputFile, OutputFile, FontDirectory: string;
    Width, Height, Scale: Single;
    PrintLayout, WholeDocument: Boolean;
  end;

  { Supplies a page's resources from local files. }
  TFileResourceLoader = class
  private
    FResources: TDocumentResources;
    FDirectory: string;
    procedure ImageNeeded(const Url, BaseUrl: string);
  public
    constructor Create(Resources: TDocumentResources; const Directory: string);
    procedure LoadElementResources(Document: TDocument);
  end;

function DefaultRenderOptions: TRenderOptions;
{ Parses a file into a document and its layout at the options' size. }
function LoadPage(const Options: TRenderOptions; out Document: TDocument; out Loader: TFileResourceLoader): TDocumentLayout;
function RenderPage(const Options: TRenderOptions): Integer;

implementation

uses
  Web.Html.Parser, Web.Atoms, Web.Text.Fonts, Web.Layout.Dump, Css.Parser, Css.Stylesheets, Image.Model,
  Image.Files, Image.StandardCodecs, Image.Codecs, Svg.Fonts, WebRender.Painting;

function DefaultRenderOptions: TRenderOptions;
begin
  Result := Default(TRenderOptions);
  Result.Width := 800;
  Result.Height := 600;
  Result.Scale := 1;
  Result.FontDirectory := '';
end;

function ReadTextFile(const Path: string): string;
var
  Stream: TFileStream;
begin
  Result := '';
  Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, Stream.Size);
    if Stream.Size > 0 then
      Stream.ReadBuffer(Result[1], Stream.Size);
  finally
    Stream.Free;
  end;
end;

function LocalPath(const Directory, Url: string): string;
var
  Clean: string;
begin
  Clean := Url;
  if Copy(Clean, 1, 7) = 'file://' then
    Delete(Clean, 1, 7);
  if (Clean <> '') and (Clean[1] = '/') then
    Result := Clean
  else
    Result := IncludeTrailingPathDelimiter(Directory) + Clean;
end;

function TryLoadImageFile(const Path: string): TImage;
begin
  Result := nil;
  if not FileExists(Path) then
    Exit;
  try
    Result := LoadImage(Path, [ImageLoadApplyOrientation]);
  except
    Result := nil;
  end;
end;

constructor TFileResourceLoader.Create(Resources: TDocumentResources; const Directory: string);
begin
  inherited Create;
  FResources := Resources;
  FDirectory := Directory;
  FResources.OnImageNeeded := @ImageNeeded;
end;

procedure TFileResourceLoader.ImageNeeded(const Url, BaseUrl: string);
var
  Image: TImage;
begin
  Image := TryLoadImageFile(LocalPath(FDirectory, Url));
  if Image <> nil then
    FResources.SetUrlImage(Url, Image);
end;

procedure TFileResourceLoader.LoadElementResources(Document: TDocument);
var
  Node: TNode;
  Element: TElement;
  Path: string;
  Image: TImage;
  Sheet: TCssStyleSheet;
begin
  Node := Document;
  while Node <> nil do
  begin
    if Node.IsElement then
    begin
      Element := TElement(Node);
      if Element.IsHtmlElement(AtomImg) and Element.HasAttributeAtom(AtomSrc) then
      begin
        Image := TryLoadImageFile(LocalPath(FDirectory, Element.AttributeValueOf(AtomSrc)));
        if Image <> nil then
          FResources.SetElementImage(Element, Image);
      end
      else if Element.IsHtmlElement(AtomLink) and
        (Pos('stylesheet', LowerCase(Element.AttributeValueOf(AtomRel))) > 0) then
      begin
        Path := LocalPath(FDirectory, Element.AttributeValueOf(AtomHref));
        if FileExists(Path) then
        begin
          Sheet := ParseStyleSheet(ReadTextFile(Path), coAuthor, Path);
          FResources.SetElementStyleSheet(Element, Sheet);
        end;
      end;
    end;
    Node := Node.NextInTree(Document);
  end;
end;

function LoadPage(const Options: TRenderOptions; out Document: TDocument; out Loader: TFileResourceLoader): TDocumentLayout;
var
  Resources: TDocumentResources;
begin
  if Options.FontDirectory <> '' then
  begin
    WebFontDirectory := Options.FontDirectory;
    SvgFontDirectory := Options.FontDirectory;
    ResetWebFontLibrary;
  end;
  Document := ParseHtmlDocument(ReadTextFile(Options.InputFile));
  Document.Url := 'file://' + ExpandFileName(Options.InputFile);
  Resources := DocumentResourcesOf(Document);
  Loader := TFileResourceLoader.Create(Resources, ExtractFileDir(ExpandFileName(Options.InputFile)));
  Loader.LoadElementResources(Document);
  Result := TDocumentLayout.Create(Document, Resources);
  Result.SetViewport(Options.Width, Options.Height, Options.Scale);
  Result.Update;
  { url() images asked for during the first layout arrived: once more. }
  if Result.NeedsUpdate then
    Result.Update;
end;

function RenderPage(const Options: TRenderOptions): Integer;
var
  Document: TDocument;
  Layout: TDocumentLayout;
  Loader: TFileResourceLoader;
begin
  Result := 0;
  try
    Layout := LoadPage(Options, Document, Loader);
  except
    on Error: Exception do
    begin
      WriteLn(StdErr, 'webrender: ', Error.Message);
      Exit(1);
    end;
  end;
  try
    if Options.PrintLayout then
      Write(DumpLayoutTree(Layout.Root));
    if Options.OutputFile <> '' then
      if not PaintPageToPng(Layout, Options.OutputFile, Options.WholeDocument) then
      begin
        WriteLn(StdErr, 'webrender: cannot write ', Options.OutputFile);
        Result := 1;
      end;
  finally
    Layout.Free;
    Loader.Free;
    FreeDocumentResources(Document);
    Document.Release;
  end;
end;

initialization
  RegisterStandardImageCodecs;
end.
