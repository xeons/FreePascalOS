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
  Web.Html.TreeBuilder: text (raw text and RCDATA elements, scripts),
  after body, in frameset, after frameset, after after body, after
  after frameset.
}

procedure THtmlTreeBuilder.ModeText(var Token: TToken);
var
  Script: TElement;
begin
  case Token.Kind of
    TokenCharacters:
      InsertCharacters(Token.Data);
    TokenEndOfFile:
      begin
        ParseError('eof-in-text');
        if CurrentNode.IsHtmlElement(AtomScript) then
          CurrentNode.ElementState := CurrentNode.ElementState or ElementStateAlreadyStarted;
        FOpenElements.Pop;
        Reprocess(FOriginalMode, Token);
      end;
    TokenEndTag:
      if Token.TagName = AtomScript then
      begin
        Script := CurrentNode;
        FOpenElements.Pop;
        FMode := FOriginalMode;
        { Preparing and running the script, and pausing the parser for
          it, is the script host's (phase 2). }
        if Assigned(FOnScriptEnd) then
          FOnScriptEnd(Script);
      end
      else
      begin
        FOpenElements.Pop;
        FMode := FOriginalMode;
      end;
  end;
end;

procedure THtmlTreeBuilder.ModeAfterBody(var Token: TToken);
begin
  case Token.Kind of
    TokenCharacters:
      { Leading whitespace would go in by the "in body" rules, which is
        what reprocessing the whole run in body does too. }
      if IsAllWhitespace(Token.Data) then
      begin
        ModeInBody(Token);
        Exit;
      end;
    TokenComment:
      begin
        InsertComment(Token.Data, FOpenElements[0]);
        Exit;
      end;
    TokenDoctype:
      begin
        ParseError('unexpected-doctype');
        Exit;
      end;
    TokenStartTag:
      if Token.TagName = AtomHtml then
      begin
        ModeInBody(Token);
        Exit;
      end;
    TokenEndTag:
      if Token.TagName = AtomHtml then
      begin
        if FContextElement <> nil then
          ParseError('unexpected-end-tag')
        else
          FMode := ImAfterAfterBody;
        Exit;
      end;
    TokenEndOfFile:
      begin
        StopParsing;
        Exit;
      end;
  end;
  ParseError('unexpected-token-after-body');
  Reprocess(ImInBody, Token);
end;

procedure THtmlTreeBuilder.ModeInFrameset(var Token: TToken);
var
  Whitespace: string;
begin
  case Token.Kind of
    TokenCharacters:
      begin
        Whitespace := WhitespaceOnly(Token.Data);
        if Length(Whitespace) <> Length(Token.Data) then
          ParseError('unexpected-character-in-frameset');
        InsertCharacters(Whitespace);
      end;
    TokenComment:
      InsertComment(Token.Data);
    TokenDoctype:
      ParseError('unexpected-doctype');
    TokenStartTag:
      case Token.TagName of
        AtomHtml:
          ModeInBody(Token);
        AtomFrameset:
          InsertHtmlElement(Token);
        AtomFrame:
          begin
            InsertHtmlElement(Token);
            FOpenElements.Pop;
            Token.SelfClosingAcknowledged := True;
          end;
        AtomNoframes:
          ModeInHead(Token);
      else
        ParseError('unexpected-start-tag');
      end;
    TokenEndTag:
      if Token.TagName = AtomFrameset then
      begin
        if FOpenElements.Count = 1 then
        begin
          ParseError('unexpected-end-tag');
          Exit;
        end;
        FOpenElements.Pop;
        if (FContextElement = nil) and not CurrentNode.IsHtmlElement(AtomFrameset) then
          FMode := ImAfterFrameset;
      end
      else
        ParseError('unexpected-end-tag');
    TokenEndOfFile:
      begin
        if FOpenElements.Count > 1 then
          ParseError('eof-in-frameset');
        StopParsing;
      end;
  end;
end;

procedure THtmlTreeBuilder.ModeAfterFrameset(var Token: TToken);
var
  Whitespace: string;
begin
  case Token.Kind of
    TokenCharacters:
      begin
        Whitespace := WhitespaceOnly(Token.Data);
        if Length(Whitespace) <> Length(Token.Data) then
          ParseError('unexpected-character-after-frameset');
        InsertCharacters(Whitespace);
      end;
    TokenComment:
      InsertComment(Token.Data);
    TokenDoctype:
      ParseError('unexpected-doctype');
    TokenStartTag:
      if Token.TagName = AtomHtml then
        ModeInBody(Token)
      else if Token.TagName = AtomNoframes then
        ModeInHead(Token)
      else
        ParseError('unexpected-start-tag');
    TokenEndTag:
      if Token.TagName = AtomHtml then
        FMode := ImAfterAfterFrameset
      else
        ParseError('unexpected-end-tag');
    TokenEndOfFile:
      StopParsing;
  end;
end;

procedure THtmlTreeBuilder.ModeAfterAfterBody(var Token: TToken);
begin
  case Token.Kind of
    TokenComment:
      begin
        InsertComment(Token.Data, FDocument);
        Exit;
      end;
    TokenDoctype:
      begin
        ModeInBody(Token);
        Exit;
      end;
    TokenCharacters:
      if IsAllWhitespace(Token.Data) then
      begin
        ModeInBody(Token);
        Exit;
      end;
    TokenStartTag:
      if Token.TagName = AtomHtml then
      begin
        ModeInBody(Token);
        Exit;
      end;
    TokenEndOfFile:
      begin
        StopParsing;
        Exit;
      end;
  end;
  ParseError('unexpected-token-after-after-body');
  Reprocess(ImInBody, Token);
end;

procedure THtmlTreeBuilder.ModeAfterAfterFrameset(var Token: TToken);
var
  Whitespace: string;
begin
  case Token.Kind of
    TokenComment:
      InsertComment(Token.Data, FDocument);
    TokenDoctype:
      ModeInBody(Token);
    TokenCharacters:
      begin
        Whitespace := WhitespaceOnly(Token.Data);
        if Length(Whitespace) <> Length(Token.Data) then
          ParseError('unexpected-character-after-after-frameset');
        if Whitespace <> '' then
        begin
          Token.Data := Whitespace;
          ModeInBody(Token);
        end;
      end;
    TokenStartTag:
      if Token.TagName = AtomHtml then
        ModeInBody(Token)
      else if Token.TagName = AtomNoframes then
        ModeInHead(Token)
      else
        ParseError('unexpected-start-tag');
    TokenEndOfFile:
      StopParsing;
  else
    ParseError('unexpected-token-after-after-frameset');
  end;
end;
