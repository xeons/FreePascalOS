{
  Library handles of the FreePascalOS System unit: the kernel's library
  handle (CallLoadLibrary).
}

type
  TLibHandle = PtrInt;

const
  NilHandle = TLibHandle(0);
  SharedSuffix = 'so';
