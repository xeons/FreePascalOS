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
  A picture in memory two processes share: a section (Objects.Sections)
  mapped by the content process, which paints a view's frames into it,
  and by the browser, which copies what changed into the tab. Pixels
  never travel through the channel; only the section's handle does,
  once, with IpcSurfaceCreated.
}
unit WebIpc.SharedSurfaces;

{$mode objfpc}
{$H+}

interface

uses
  Drawing.Surfaces;

type
  TSharedSurface = class
  private
    FSection: Int64;
    FPixels: Pointer;
    FWidth, FHeight: LongInt;
    FStrideBytes: LongInt;
    FSurface: TSurface;
    FByteCount: QWord;
  public
    { A new section for Width x Height pixels (nil when there is no
      memory for it). }
    class function CreateNew(Width, Height: LongInt): TSharedSurface;
    { Maps a section another process made (Handle is the surface's from
      now on); nil when it cannot be mapped or is too small. }
    class function OpenSection(Handle: Int64; Width, Height, StrideBytes: LongInt): TSharedSurface;
    destructor Destroy; override;
    { A handle of the section to send (the caller's to give away). }
    function DuplicateSection: Int64;
    property Surface: TSurface read FSurface;
    property Width: LongInt read FWidth;
    property Height: LongInt read FHeight;
    property StrideBytes: LongInt read FStrideBytes;
    property Section: Int64 read FSection;
  end;

implementation

uses
  Sys.Objects,
  Sys.Processes;

const
  PageBytes = 4096;

function PageRounded(Count: QWord): QWord;
begin
  Result := (Count + PageBytes - 1) and not QWord(PageBytes - 1);
end;

class function TSharedSurface.CreateNew(Width, Height: LongInt): TSharedSurface;
var
  NewSection: Int64;
  Bytes: QWord;
  Pixels: Pointer;
begin
  Result := nil;
  if (Width <= 0) or (Height <= 0) then
    Exit;
  Bytes := PageRounded(QWord(Width) * QWord(Height) * 4);
  NewSection := CreateSection(Bytes);
  if NewSection < 0 then
    Exit;
  Pixels := MapSection(NewSection, 0, Bytes);
  if Pixels = nil then
  begin
    CloseHandle(NewSection);
    Exit;
  end;
  Result := TSharedSurface.Create;
  Result.FSection := NewSection;
  Result.FPixels := Pixels;
  Result.FWidth := Width;
  Result.FHeight := Height;
  Result.FStrideBytes := Width * 4;
  Result.FByteCount := Bytes;
  Result.FSurface := SurfaceOnPixels(Pixels, Width, Height, Width * 4);
end;

class function TSharedSurface.OpenSection(Handle: Int64; Width, Height, StrideBytes: LongInt): TSharedSurface;
var
  Bytes: QWord;
  Pixels: Pointer;
begin
  Result := nil;
  if (Width <= 0) or (Height <= 0) or (StrideBytes < Width * 4) then
  begin
    CloseHandle(Handle);
    Exit;
  end;
  Bytes := PageRounded(QWord(StrideBytes) * QWord(Height));
  { A section smaller than that fails to map whole. }
  Pixels := MapSection(Handle, 0, Bytes);
  if Pixels = nil then
  begin
    CloseHandle(Handle);
    Exit;
  end;
  Result := TSharedSurface.Create;
  Result.FSection := Handle;
  Result.FPixels := Pixels;
  Result.FWidth := Width;
  Result.FHeight := Height;
  Result.FStrideBytes := StrideBytes;
  Result.FByteCount := Bytes;
  Result.FSurface := SurfaceOnPixels(Pixels, Width, Height, StrideBytes);
end;

destructor TSharedSurface.Destroy;
begin
  if FPixels <> nil then
    UnmapSection(FPixels);
  if FSection >= 0 then
    CloseHandle(FSection);
  inherited Destroy;
end;

function TSharedSurface.DuplicateSection: Int64;
begin
  Result := DuplicateHandle(FSection, -1);
end;

end.
