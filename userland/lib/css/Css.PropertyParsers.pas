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
  Registers the value routines the property table's '@name' grammars
  refer to.
}
unit Css.PropertyParsers;

{$mode objfpc}
{$H+}

interface

implementation

uses
  Css.Grammar, Css.BoxParsers, Css.GridParsers, Css.TextParsers;

procedure RegisterRoutines;
begin
  RegisterValueRoutine('display', @ParseDisplay);
  RegisterValueRoutine('size', @ParseSize);
  RegisterValueRoutine('max-size', @ParseMaxSize);
  RegisterValueRoutine('flex-basis', @ParseFlexBasis);
  RegisterValueRoutine('content-alignment', @ParseContentAlignment);
  RegisterValueRoutine('items-alignment', @ParseItemsAlignment);
  RegisterValueRoutine('self-alignment', @ParseSelfAlignment);
  RegisterValueRoutine('justify-items', @ParseJustifyItems);
  RegisterValueRoutine('aspect-ratio', @ParseAspectRatio);
  RegisterValueRoutine('radius-corner', @ParseRadiusCorner);
  RegisterValueRoutine('border-spacing', @ParseBorderSpacing);
  RegisterValueRoutine('border-image-slice', @ParseBorderImageSlice);
  RegisterValueRoutine('border-image-width', @ParseBorderImageWidth);
  RegisterValueRoutine('border-image-outset', @ParseBorderImageOutset);
  RegisterValueRoutine('border-image-repeat', @ParseBorderImageRepeat);
  RegisterValueRoutine('background-position-x', @ParseBackgroundPositionX);
  RegisterValueRoutine('background-position-y', @ParseBackgroundPositionY);
  RegisterValueRoutine('background-size', @ParseBackgroundSize);
  RegisterValueRoutine('background-repeat', @ParseBackgroundRepeat);
  RegisterValueRoutine('transform-origin', @ParseTransformOrigin);
  RegisterValueRoutine('position', @ParsePositionValue);
  RegisterValueRoutine('transform', @ParseTransformValue);
  RegisterValueRoutine('translate', @ParseTranslateValue);
  RegisterValueRoutine('rotate', @ParseRotateValue);
  RegisterValueRoutine('scale', @ParseScaleValue);
  RegisterValueRoutine('will-change', @ParseWillChange);
  RegisterValueRoutine('container-name', @ParseContainerName);
  RegisterValueRoutine('clip', @ParseClip);
  RegisterValueRoutine('clip-path', @ParseClipPath);
  RegisterValueRoutine('filter', @ParseFilter);
  RegisterValueRoutine('scrollbar-color', @ParseScrollbarColor);
  RegisterValueRoutine('track-list', @ParseTrackListValue);
  RegisterValueRoutine('grid-template-areas', @ParseGridTemplateAreas);
  RegisterValueRoutine('track-sizes', @ParseTrackSizes);
  RegisterValueRoutine('grid-auto-flow', @ParseGridAutoFlow);
  RegisterValueRoutine('grid-line', @ParseGridLine);
  RegisterValueRoutine('font-family', @ParseFontFamily);
  RegisterValueRoutine('font-style', @ParseFontStyle);
  RegisterValueRoutine('font-feature-settings', @ParseFontFeatureSettings);
  RegisterValueRoutine('font-variation-settings', @ParseFontVariationSettings);
  RegisterValueRoutine('text-shadow', @ParseTextShadow);
  RegisterValueRoutine('box-shadow', @ParseBoxShadow);
  RegisterValueRoutine('cursor', @ParseCursor);
  RegisterValueRoutine('color-scheme', @ParseColorScheme);
  RegisterValueRoutine('list-style-type', @ParseListStyleType);
  RegisterValueRoutine('quotes', @ParseQuotes);
  RegisterValueRoutine('text-overflow', @ParseTextOverflow);
  RegisterValueRoutine('content', @ParseContent);
  RegisterValueRoutine('counter-reset', @ParseCounterReset);
  RegisterValueRoutine('counter-increment', @ParseCounterIncrement);
  RegisterValueRoutine('counter-set', @ParseCounterReset);
  RegisterValueRoutine('transition-property', @ParseTransitionProperty);
  RegisterValueRoutine('easing-list', @ParseEasingList);
  RegisterValueRoutine('animation-name', @ParseAnimationName);
end;

initialization
  RegisterRoutines;
end.
