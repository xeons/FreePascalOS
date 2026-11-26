// HTMLInputElement.valueAsDate (HTML Standard 4.10.5.4) for the date,
// month, week and time types, over valueAsNumber (milliseconds since
// the epoch, since midnight for time; months since January 1970 for
// month, which a Date gives as the first of its month in UTC).
(function (natives, global, internal) {
  "use strict";
  const DateClass = global.Date;
  const InputPrototype = global.HTMLInputElement.prototype;
  const numberDescriptor = Object.getOwnPropertyDescriptor(InputPrototype, "valueAsNumber");
  const typeDescriptor = Object.getOwnPropertyDescriptor(InputPrototype, "type");
  const dateTypes = ["date", "month", "week", "time"];

  function typeOf(input) {
    return typeDescriptor.get.call(input);
  }

  Object.defineProperty(InputPrototype, "valueAsDate", {
    get: function () {
      const type = typeOf(this);
      if (dateTypes.indexOf(type) < 0) return null;
      const number = numberDescriptor.get.call(this);
      if (Number.isNaN(number)) return null;
      if (type === "month") {
        const year = 1970 + Math.floor(number / 12);
        return new DateClass(DateClass.UTC(year, number - (year - 1970) * 12, 1));
      }
      return new DateClass(number);
    },
    set: function (value) {
      const type = typeOf(this);
      if (dateTypes.indexOf(type) < 0)
        throw internal.domException("Failed to set the 'valueAsDate' property on 'HTMLInputElement': This input " +
          "element does not support Date values.", "InvalidStateError");
      if (value === null) {
        numberDescriptor.set.call(this, NaN);
        return;
      }
      if (!(value instanceof DateClass))
        throw new TypeError("Failed to set the 'valueAsDate' property on 'HTMLInputElement': The provided value " +
          "is not a Date.");
      const time = value.getTime();
      if (Number.isNaN(time)) numberDescriptor.set.call(this, NaN);
      else if (type === "month")
        numberDescriptor.set.call(this, (value.getUTCFullYear() - 1970) * 12 + value.getUTCMonth());
      else numberDescriptor.set.call(this, time);
    },
    configurable: true,
    enumerable: true
  });
})
