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
  What a recursion has fetched: each URL (and the URL its redirections
  ended at) with the file it is in and whether it is a page, so links
  can be converted (-k) once everything is there. URLs are kept as
  FormatUrl writes them, without fragments.
}
unit Wget.Downloads;

{$mode objfpc}
{$H+}

interface

uses
  Classes,
  Wget.Urls;

type
  TDownload = record
    Url: TUrl;
    LocalPath: string;
    IsPage: Boolean;
  end;

  TDownloadList = class
  private
    FDownloads: array of TDownload;
    { URL text -> index into FDownloads. }
    FIndex: TStringList;
    function GetCount: Integer;
    function GetDownload(Index: Integer): TDownload;
  public
    constructor Create;
    destructor Destroy; override;
    { Url was saved to LocalPath; FinalUrl (after redirections) leads
      there too. }
    procedure Add(constref Url, FinalUrl: TUrl; const LocalPath: string; IsPage: Boolean);
    { The file a URL was saved to; False if it was not fetched. }
    function FindLocalPath(constref Url: TUrl; out LocalPath: string): Boolean;
    property Count: Integer read GetCount;
    property Downloads[Index: Integer]: TDownload read GetDownload;
  end;

implementation

uses
  SysUtils;

constructor TDownloadList.Create;
begin
  inherited Create;
  FIndex := TStringList.Create;
  FIndex.Sorted := True;
  FIndex.Duplicates := dupIgnore;
  FIndex.CaseSensitive := True;
end;

destructor TDownloadList.Destroy;
begin
  FIndex.Free;
  inherited Destroy;
end;

function TDownloadList.GetCount: Integer;
begin
  Result := Length(FDownloads);
end;

function TDownloadList.GetDownload(Index: Integer): TDownload;
begin
  Result := FDownloads[Index];
end;

procedure TDownloadList.Add(constref Url, FinalUrl: TUrl; const LocalPath: string; IsPage: Boolean);
var
  Entry: TDownload;
begin
  Entry.Url := Url;
  Entry.LocalPath := LocalPath;
  Entry.IsPage := IsPage;
  SetLength(FDownloads, Length(FDownloads) + 1);
  FDownloads[High(FDownloads)] := Entry;
  FIndex.AddObject(FormatUrl(Url), TObject(PtrInt(High(FDownloads))));
  FIndex.AddObject(FormatUrl(FinalUrl), TObject(PtrInt(High(FDownloads))));
end;

function TDownloadList.FindLocalPath(constref Url: TUrl; out LocalPath: string): Boolean;
var
  Position: Integer;
begin
  LocalPath := '';
  Result := FIndex.Find(FormatUrl(Url), Position);
  if Result then
    LocalPath := FDownloads[PtrInt(FIndex.Objects[Position])].LocalPath;
end;

end.
