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
  What the loading side hands to the style, layout and painting side
  (the contract between them). The loader fetches, decodes and parses;
  the sink attaches the results to the document. All calls come on the
  page thread, between tasks' steps.

  - StyleSheetLoaded: a <link rel=stylesheet> sheet, parsed by libcss,
    every @import in it (to any depth) already loaded and hung on its
    rule (TCssImportRule.StyleSheet; one that failed stays nil). The
    sheet's Href is its final URL (the base for its url() values), its
    Media the link's media attribute, Disabled the link's state. The
    sink owns the sheet from then on. StyleSheetRemoved: the link went
    (removed, rel or href changed, disabled); drop its sheet.
  - ImportsLoaded: the sink gave the loader a sheet of its own (a
    <style> element's, LoadImportsOf) and its imports are now in place.
    The sheet stays the sink's.
  - ImageLoaded: an <img> (or <input type=image>, <picture>'s img)
    decoded: the pixels, downscaled when they were much larger than
    needed, and the natural size in CSS pixels (density corrected, from
    before any downscaling), which layout uses. The sink owns the image.
    ImageFailed: the image cannot be shown (alt text). ImageRemoved:
    drop what it had for the element.
  - FontLoaded: an @font-face source fetched (the bytes as they came:
    TrueType, OpenType, WOFF, WOFF2); FontFailed: none of its sources
    could be loaded. FontFormatSupported says which format() hints are
    worth fetching.
  - MediaEnvironment: the viewport, device pixel ratio and preferences
    for link media, sizes and srcset.

  TNullResourceSink throws everything away (a document nobody renders,
  tests).
}
unit Web.Loading.ResourceSink;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Css.Keywords,
  Css.MediaQueries,
  Css.Stylesheets,
  Image.Model,
  Web.Dom;

type
  TLoadedImageInfo = record
    { CSS pixels: the image's pixel size divided by its density. }
    NaturalWidth: Double;
    NaturalHeight: Double;
    { The density the image was chosen for (srcset x descriptor). }
    Density: Double;
    { The URL it came from (currentSrc). }
    CurrentUrl: string;
    { The pixels were scaled down from a larger image. }
    Downscaled: Boolean;
    { The image has more frames (animation), not decoded yet. }
    Animated: Boolean;
  end;

  TResourceSink = class
  public
    procedure StyleSheetLoaded(Owner: TElement; Sheet: TCssStyleSheet); virtual; abstract;
    procedure StyleSheetRemoved(Owner: TElement); virtual; abstract;
    procedure ImportsLoaded(Owner: TElement; Sheet: TCssStyleSheet); virtual; abstract;
    procedure ImageLoaded(Element: TElement; Image: TImage; constref Info: TLoadedImageInfo); virtual; abstract;
    procedure ImageFailed(Element: TElement); virtual; abstract;
    procedure ImageRemoved(Element: TElement); virtual; abstract;
    procedure FontLoaded(Rule: TCssFontFaceRule; const Family: string; const Data: TBytes;
      const Url: string); virtual; abstract;
    procedure FontFailed(Rule: TCssFontFaceRule; const Family: string); virtual; abstract;
    { format() hints worth fetching ('' when the source gave none). }
    function FontFormatSupported(const Format: string): Boolean; virtual;
    function MediaEnvironment: TCssMediaEnvironment; virtual;
  end;

  TNullResourceSink = class(TResourceSink)
  private
    FEnvironment: TCssMediaEnvironment;
  public
    constructor Create;
    procedure StyleSheetLoaded(Owner: TElement; Sheet: TCssStyleSheet); override;
    procedure StyleSheetRemoved(Owner: TElement); override;
    procedure ImportsLoaded(Owner: TElement; Sheet: TCssStyleSheet); override;
    procedure ImageLoaded(Element: TElement; Image: TImage; constref Info: TLoadedImageInfo); override;
    procedure ImageFailed(Element: TElement); override;
    procedure ImageRemoved(Element: TElement); override;
    procedure FontLoaded(Rule: TCssFontFaceRule; const Family: string; const Data: TBytes;
      const Url: string); override;
    procedure FontFailed(Rule: TCssFontFaceRule; const Family: string); override;
    function MediaEnvironment: TCssMediaEnvironment; override;
    property Environment: TCssMediaEnvironment read FEnvironment write FEnvironment;
  end;

{ A screen of Width x Height CSS pixels at Ratio device pixels each. }
function ScreenMediaEnvironment(Width, Height, Ratio: Double): TCssMediaEnvironment;

implementation

function ScreenMediaEnvironment(Width, Height, Ratio: Double): TCssMediaEnvironment;
begin
  Result := DefaultMediaEnvironment;
  Result.MediaType := kwScreen;
  Result.Width := Width;
  Result.Height := Height;
  Result.DeviceWidth := Width;
  Result.DeviceHeight := Height;
  Result.Resolution := Ratio;
end;

function TResourceSink.FontFormatSupported(const Format: string): Boolean;
begin
  Result := (Format = '') or (Format = 'truetype') or (Format = 'opentype') or (Format = 'woff') or
    (Format = 'woff2') or (Format = 'collection');
end;

function TResourceSink.MediaEnvironment: TCssMediaEnvironment;
begin
  Result := ScreenMediaEnvironment(1024, 768, 1);
end;

constructor TNullResourceSink.Create;
begin
  inherited Create;
  FEnvironment := ScreenMediaEnvironment(1024, 768, 1);
end;

procedure TNullResourceSink.StyleSheetLoaded(Owner: TElement; Sheet: TCssStyleSheet);
begin
  Sheet.Free;
end;

procedure TNullResourceSink.StyleSheetRemoved(Owner: TElement);
begin
end;

procedure TNullResourceSink.ImportsLoaded(Owner: TElement; Sheet: TCssStyleSheet);
begin
end;

procedure TNullResourceSink.ImageLoaded(Element: TElement; Image: TImage; constref Info: TLoadedImageInfo);
begin
  Image.Free;
end;

procedure TNullResourceSink.ImageFailed(Element: TElement);
begin
end;

procedure TNullResourceSink.ImageRemoved(Element: TElement);
begin
end;

procedure TNullResourceSink.FontLoaded(Rule: TCssFontFaceRule; const Family: string; const Data: TBytes;
  const Url: string);
begin
end;

procedure TNullResourceSink.FontFailed(Rule: TCssFontFaceRule; const Family: string);
begin
end;

function TNullResourceSink.MediaEnvironment: TCssMediaEnvironment;
begin
  Result := FEnvironment;
end;

end.
