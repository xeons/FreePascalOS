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
  A page's source as the Page Source window shows it: HTML of a <pre>
  with the markup coloured as the old source viewers did - tag names,
  attribute names, attribute values, comments, the doctype and
  character references each in a class (the style sheet gives the
  colours) - and the text escaped. Long lines wrap when Wrap is set.
  Plain logic, checked on the host.
}
unit Browser.SourceColoring;

{$mode objfpc}
{$H+}

interface

{ The whole page showing Source; Title names it. }
function ColoredSourcePage(const Source, Title: string; Wrap: Boolean): string;
{ Only the coloured markup (what goes in the <pre>). }
function ColorSource(const Source: string): string;

implementation

uses
  SysUtils;

function Escape(const Text: string): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 1 to Length(Text) do
    case Text[Index] of
      '&': Result := Result + '&amp;';
      '<': Result := Result + '&lt;';
      '>': Result := Result + '&gt;';
      '"': Result := Result + '&quot;';
    else
      Result := Result + Text[Index];
    end;
end;

function Span(const ClassName, Text: string): string;
begin
  Result := '<span class="' + ClassName + '">' + Escape(Text) + '</span>';
end;

{ A tag from Source[Start] ('<') to its '>' (or the end), coloured. }
function ColorTag(const Source: string; var Position: Integer): string;
var
  Start, Length_: Integer;
  Quote: Char;
begin
  Length_ := Length(Source);
  Start := Position;
  { The name, with "<" or "</". }
  Inc(Position);
  if (Position <= Length_) and (Source[Position] = '/') then
    Inc(Position);
  while (Position <= Length_) and not (Source[Position] in [' ', #9, #10, #13, '>', '/']) do
    Inc(Position);
  Result := Span('tag', Copy(Source, Start, Position - Start));
  while Position <= Length_ do
  begin
    case Source[Position] of
      '>':
        begin
          Result := Result + Span('tag', '>');
          Inc(Position);
          Exit;
        end;
      ' ', #9, #10, #13:
        begin
          Result := Result + Source[Position];
          Inc(Position);
        end;
      '/':
        begin
          Result := Result + Span('tag', '/');
          Inc(Position);
        end;
      '=':
        begin
          Result := Result + '=';
          Inc(Position);
          { The value: quoted or not. }
          if (Position <= Length_) and (Source[Position] in ['"', '''']) then
          begin
            Quote := Source[Position];
            Start := Position;
            Inc(Position);
            while (Position <= Length_) and (Source[Position] <> Quote) do
              Inc(Position);
            if Position <= Length_ then
              Inc(Position);
            Result := Result + Span('value', Copy(Source, Start, Position - Start));
          end
          else
          begin
            Start := Position;
            while (Position <= Length_) and not (Source[Position] in [' ', #9, #10, #13, '>']) do
              Inc(Position);
            Result := Result + Span('value', Copy(Source, Start, Position - Start));
          end;
        end;
    else
      begin
        Start := Position;
        while (Position <= Length_) and not (Source[Position] in [' ', #9, #10, #13, '>', '=', '/']) do
          Inc(Position);
        Result := Result + Span('attribute', Copy(Source, Start, Position - Start));
      end;
    end;
  end;
end;

function ColorSource(const Source: string): string;
var
  Position, Start, Finish: Integer;
  Text: string;
begin
  Result := '';
  Position := 1;
  while Position <= Length(Source) do
  begin
    if Copy(Source, Position, 4) = '<!--' then
    begin
      Finish := Pos('-->', Source, Position + 4);
      if Finish = 0 then
        Finish := Length(Source) + 1
      else
        Inc(Finish, 3);
      Result := Result + Span('comment', Copy(Source, Position, Finish - Position));
      Position := Finish;
    end
    else if (Copy(Source, Position, 2) = '<!') or (Copy(Source, Position, 2) = '<?') then
    begin
      Finish := Pos('>', Source, Position);
      if Finish = 0 then
        Finish := Length(Source)
      else if Finish < Position then
        Finish := Length(Source);
      Result := Result + Span('doctype', Copy(Source, Position, Finish - Position + 1));
      Position := Finish + 1;
    end
    else if (Source[Position] = '<') and (Position < Length(Source)) and
            (Source[Position + 1] in ['a'..'z', 'A'..'Z', '/']) then
      Result := Result + ColorTag(Source, Position)
    else if Source[Position] = '&' then
    begin
      Start := Position;
      Inc(Position);
      while (Position <= Length(Source)) and (Position - Start < 12) and
            (Source[Position] in ['a'..'z', 'A'..'Z', '0'..'9', '#']) do
        Inc(Position);
      if (Position <= Length(Source)) and (Source[Position] = ';') then
      begin
        Inc(Position);
        Result := Result + Span('entity', Copy(Source, Start, Position - Start));
      end
      else
        Result := Result + Escape(Copy(Source, Start, Position - Start));
    end
    else
    begin
      Start := Position;
      while (Position <= Length(Source)) and not (Source[Position] in ['<', '&']) do
        Inc(Position);
      if Position = Start then
        Inc(Position);
      Text := Copy(Source, Start, Position - Start);
      Result := Result + Escape(Text);
    end;
  end;
end;

function ColoredSourcePage(const Source, Title: string; Wrap: Boolean): string;
var
  WhiteSpace: string;
begin
  if Wrap then
    WhiteSpace := 'pre-wrap'
  else
    WhiteSpace := 'pre';
  Result := '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Source of: ' + Escape(Title) + '</title>' +
    '<style>body{margin:0;background:#fff;color:#000}pre{margin:4px 6px;font-family:monospace;font-size:13px;' +
    'white-space:' + WhiteSpace + '}.tag{color:#881280;font-weight:bold}.attribute{color:#000;font-weight:bold}' +
    '.value{color:#1a1aa6}.comment{color:#236e25;font-style:italic}.doctype{color:#808080;font-style:italic}' +
    '.entity{color:#ff4500}</style></head><body><pre>' + ColorSource(Source) + '</pre></body></html>';
end;

end.
