// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//
//  IOSReflection.m
//  JreEmulation
//
//  Created by Keith Stanger on Nov 12, 2013.
//

#import "IOSReflection.h"

#import "IOSClass.h"
#import "java/lang/AssertionError.h"
#import "java/lang/reflect/Constructor.h"
#import "java/lang/reflect/Method.h"
#import "objc/message.h"

const J2ObjcClassInfo JreEmptyClassInfo = {
    NULL, NULL, NULL, NULL, NULL, J2OBJC_METADATA_VERSION, 0x0, 0, 0, -1, -1, -1, -1, -1 };

const J2ObjcClassInfo *JreFindMetadata(Class cls) {
  // Can't use respondsToSelector here because that will search superclasses.
  Method metadataMethod = cls ? JreFindClassMethod(cls, "__metadata") : NULL;
  if (metadataMethod) {
    const J2ObjcClassInfo *metadata = (const J2ObjcClassInfo *)method_invoke(cls, metadataMethod);
    // We don't use any Java based assert or throwables here because this function is called during
    // IOSClass construction under mutual exclusion so causing any other IOSClass to be initialized
    // would result in deadlock.
    NSCAssert(metadata->version == J2OBJC_METADATA_VERSION,
        @"J2ObjC metadata is out-of-date, source must be re-translated.");
    return metadata;
  }
  return NULL;
}

// Parses the next IOSClass from the delimited string, advancing the c-string pointer past the
// parsed type.
static IOSClass *ParseNextClass(const char **strPtr) {
  const char c = *(*strPtr)++;
  if (c == '[') {
    return IOSClass_arrayOf(ParseNextClass(strPtr));
  } else if (c == 'L') {
    const char *delimitor = strchr(*strPtr, ';');
    NSString *name = [[NSString alloc] initWithBytes:*strPtr
                                              length:delimitor - *strPtr
                                             encoding:NSUTF8StringEncoding];
    *strPtr = delimitor + 1;
    IOSClass *result = [IOSClass classForIosName:name];
    [name release];
    return result;
  }
  IOSClass *primitiveType = [IOSClass primitiveClassForChar:c];
  if (primitiveType) {
    return primitiveType;
  }
  // Bad reflection data. Caller should throw AssertionError.
  return nil;
}

IOSClass *JreClassForString(const char * const str) {
  const char *ptr = str;
  IOSClass *result = ParseNextClass(&ptr);
  if (!result) {
    @throw create_JavaLangAssertionError_initWithId_(
      [NSString stringWithFormat:@"invalid type from metadata %s", str]);
  }
  return result;
}

IOSObjectArray *JreParseClassList(const char * const listStr) {
  if (!listStr) {
    return [IOSObjectArray arrayWithLength:0 type:IOSClass_class_()];
  }
  const char *ptr = listStr;
  NSMutableArray *builder = [NSMutableArray array];
  while (*ptr) {
    IOSClass *nextClass = ParseNextClass(&ptr);
    if (!nextClass) {
      @throw create_JavaLangAssertionError_initWithId_(
          [NSString stringWithFormat:@"invalid type list from metadata %s", listStr]);
    }
    [builder addObject:nextClass];
  }
  return [IOSObjectArray arrayWithNSArray:builder type:IOSClass_class_()];
}

Method JreFindInstanceMethod(Class cls, const char *name) {
  unsigned int count;
  Method result = nil;
  Method *methods = class_copyMethodList(cls, &count);
  for (NSUInteger i = 0; i < count; i++) {
    if (strcmp(name, sel_getName(method_getName(methods[i]))) == 0) {
      result = methods[i];
      break;
    }
  }
  free(methods);
  return result;
}

Method JreFindClassMethod(Class cls, const char *name) {
  return JreFindInstanceMethod(object_getClass(cls), name);
}

struct objc_method_description *JreFindMethodDescFromList(
    SEL sel, struct objc_method_description *methods, unsigned int count) {
  for (unsigned int i = 0; i < count; i++) {
    if (sel == methods[i].name) {
      return &methods[i];
    }
  }
  return NULL;
}

struct objc_method_description *JreFindMethodDescFromMethodList(
    SEL sel, Method *methods, unsigned int count) {
  for (unsigned int i = 0; i < count; i++) {
    struct objc_method_description *desc = method_getDescription(methods[i]);
    if (sel == desc->name) {
      return desc;
    }
  }
  return NULL;
}

static NSMethodSignature *JreSignatureOrNull(struct objc_method_description *methodDesc) {
  const char *types = methodDesc->types;
  if (!types) {
    return nil;
  }
  // Some IOS devices crash instead of throwing an exception on struct type
  // encodings.
  const char *badChar = strchr(types, '{');
  if (badChar) {
    return nil;
  }
  @try {
    // Fails when non-ObjC types are included in the type encoding.
    return [NSMethodSignature signatureWithObjCTypes:types];
  }
  @catch (NSException *e) {
    return nil;
  }
}

static NSString *MetadataNameList(IOSObjectArray *classes) {
  if (!classes || classes->size_ == 0) {
    return nil;
  }
  NSMutableString *str = [NSMutableString string];
  for (IOSClass *cls in classes) {
    if (!cls) {
      return @"";  // Won't match anything.
    }
    [cls appendMetadataName:str];
  }
  return str;
}

const J2ObjcFieldInfo *JreFindFieldInfo(const J2ObjcClassInfo *metadata, const char *fieldName) {
  if (metadata) {
    for (int i = 0; i < metadata->fieldCount; i++) {
      const J2ObjcFieldInfo *fieldInfo = &metadata->fields[i];
      const char *javaName = JrePtrAtIndex(metadata->ptrTable, fieldInfo->javaNameIdx);
      if (javaName && strcmp(fieldName, javaName) == 0) {
        return fieldInfo;
      }
      if (strcmp(fieldName, fieldInfo->name) == 0) {
        return fieldInfo;
      }
      // See if field name has trailing underscore added.
      size_t max  = strlen(fieldInfo->name) - 1;
      if (fieldInfo->name[max] == '_' && strlen(fieldName) == max &&
          strncmp(fieldName, fieldInfo->name, max) == 0) {
        return fieldInfo;
      }
    }
  }
  return NULL;
}

NSString *JreClassTypeName(const J2ObjcClassInfo *metadata) {
  return metadata ? [NSString stringWithUTF8String:metadata->typeName] : nil;
}

NSString *JreClassPackageName(const J2ObjcClassInfo *metadata) {
  return metadata && metadata->packageName
      ? [NSString stringWithUTF8String:metadata->packageName] : nil;
}

static JavaLangReflectMethod *MethodFromMetadata(
    IOSClass *iosClass, const J2ObjcMethodInfo *methodInfo) {
  SEL sel = sel_registerName(methodInfo->selector);
  Class cls = iosClass.objcClass;
  NSMethodSignature *signature = nil;
  bool isStatic = (methodInfo->modifiers & JavaLangReflectModifier_STATIC) > 0;
  if (isStatic) {
    if (cls) {
      Method method = JreFindClassMethod(cls, methodInfo->selector);
      if (method) {
        signature = JreSignatureOrNull(method_getDescription(method));
      }
    }
  } else {
    Protocol *protocol = iosClass.objcProtocol;
    if (protocol) {
      struct objc_method_description methodDesc =
          protocol_getMethodDescription(protocol, sel, YES, YES);
      signature = JreSignatureOrNull(&methodDesc);
    } else if (cls) {
      Method method = JreFindInstanceMethod(cls, methodInfo->selector);
      if (method) {
        signature = JreSignatureOrNull(method_getDescription(method));
      }
    }
  }
  if (!signature) {
    return nil;
  }
  return [JavaLangReflectMethod methodWithMethodSignature:signature
                                                 selector:sel
                                                    class:iosClass
                                                 isStatic:isStatic
                                                 metadata:methodInfo];
}

static JavaLangReflectConstructor *ConstructorFromMetadata(
    IOSClass *iosClass, const J2ObjcMethodInfo *methodInfo) {
  Class cls = iosClass.objcClass;
  if (!cls) {
    return nil;
  }
  Method method = JreFindInstanceMethod(cls, methodInfo->selector);
  if (!method) {
    return nil;
  }
  NSMethodSignature *signature = JreSignatureOrNull(method_getDescription(method));
  if (!signature) {
    return nil;
  }
  return [JavaLangReflectConstructor constructorWithMethodSignature:signature
                                                           selector:method_getName(method)
                                                              class:iosClass
                                                           metadata:methodInfo];
}

static bool NullableCStrEquals(const char *a, const char *b) {
  return (a == NULL && b == NULL) || (a != NULL && b != NULL && strcmp(a, b) == 0);
}

JavaLangReflectMethod *JreMethodWithNameAndParamTypes(
    IOSClass *iosClass, NSString *name, IOSObjectArray *paramTypes) {
  const J2ObjcClassInfo *metadata = IOSClass_GetMetadataOrFail(iosClass);
  const void **ptrTable = metadata->ptrTable;
  const char *cname = [name UTF8String];
  const char *cparams = [MetadataNameList(paramTypes) UTF8String];
  for (int i = 0; i < metadata->methodCount; i++) {
    const J2ObjcMethodInfo *methodInfo = &metadata->methods[i];
    if (methodInfo->returnType && strcmp(JreMethodJavaName(methodInfo, ptrTable), cname) == 0
        && NullableCStrEquals(JrePtrAtIndex(ptrTable, methodInfo->paramsIdx), cparams)) {
      return MethodFromMetadata(iosClass, methodInfo);
    }
  }
  return nil;
}

JavaLangReflectConstructor *JreConstructorWithParamTypes(
    IOSClass *iosClass, IOSObjectArray *paramTypes) {
  const J2ObjcClassInfo *metadata = IOSClass_GetMetadataOrFail(iosClass);
  const void **ptrTable = metadata->ptrTable;
  const char *cparams = [MetadataNameList(paramTypes) UTF8String];
  for (int i = 0; i < metadata->methodCount; i++) {
    const J2ObjcMethodInfo *methodInfo = &metadata->methods[i];
    if (!methodInfo->returnType
        && NullableCStrEquals(JrePtrAtIndex(ptrTable, methodInfo->paramsIdx), cparams)) {
      return ConstructorFromMetadata(iosClass, methodInfo);
    }
  }
  return nil;
}

JavaLangReflectMethod *JreMethodForSelector(IOSClass *iosClass, const char *selector) {
  const J2ObjcClassInfo *metadata = IOSClass_GetMetadataOrFail(iosClass);
  for (int i = 0; i < metadata->methodCount; i++) {
    const J2ObjcMethodInfo *methodInfo = &metadata->methods[i];
    if (strcmp(selector, methodInfo->selector) == 0 && methodInfo->returnType) {
      return MethodFromMetadata(iosClass, methodInfo);
    }
  }
  return nil;
}

JavaLangReflectConstructor *JreConstructorForSelector(IOSClass *iosClass, const char *selector) {
  const J2ObjcClassInfo *metadata = IOSClass_GetMetadataOrFail(iosClass);
  for (int i = 0; i < metadata->methodCount; i++) {
    const J2ObjcMethodInfo *methodInfo = &metadata->methods[i];
    if (strcmp(selector, methodInfo->selector) == 0 && !methodInfo->returnType) {
      return ConstructorFromMetadata(iosClass, methodInfo);
    }
  }
  return nil;
}

JavaLangReflectMethod *JreMethodWithNameAndParamTypesInherited(
    IOSClass *iosClass, NSString *name, IOSObjectArray *types) {
  JavaLangReflectMethod *method = JreMethodWithNameAndParamTypes(iosClass, name, types);
  if (method) {
    return method;
  }
  for (IOSClass *p in [iosClass getInterfacesInternal]) {
    method = JreMethodWithNameAndParamTypesInherited(p, name, types);
    if (method) {
      return method;
    }
  }
  IOSClass *superclass = [iosClass getSuperclass];
  return superclass ? JreMethodWithNameAndParamTypesInherited(superclass, name, types) : nil;
}

JavaLangReflectMethod *JreMethodForSelectorInherited(IOSClass *iosClass, const char *selector) {
  JavaLangReflectMethod *method = JreMethodForSelector(iosClass, selector);
  if (method) {
    return method;
  }
  for (IOSClass *p in [iosClass getInterfacesInternal]) {
    method = JreMethodForSelectorInherited(p, selector);
    if (method) {
      return method;
    }
  }
  IOSClass *superclass = [iosClass getSuperclass];
  return superclass ? JreMethodForSelectorInherited(superclass, selector) : nil;
}

NSString *JreMethodGenericString(const J2ObjcMethodInfo *metadata, const void **ptrTable) {
  const char *genericSig = metadata ? JrePtrAtIndex(ptrTable, metadata->genericSignatureIdx) : NULL;
  return genericSig ? [NSString stringWithUTF8String:genericSig] : nil;
}

static NSMutableString *BuildQualifiedName(const J2ObjcClassInfo *metadata) {
  if (!metadata) {
    return nil;
  }
  const char *enclosingClass = JrePtrAtIndex(metadata->ptrTable, metadata->enclosingClassIdx);
  if (enclosingClass) {
    NSMutableString *qName = BuildQualifiedName([JreClassForString(enclosingClass) getMetadata]);
    if (!qName) {
      return nil;
    }
    [qName appendString:@"$"];
    [qName appendString:[NSString stringWithUTF8String:metadata->typeName]];
    return qName;
  } else if (metadata->packageName) {
    NSMutableString *qName = [NSMutableString stringWithUTF8String:metadata->packageName];
    [qName appendString:@"."];
    [qName appendString:[NSString stringWithUTF8String:metadata->typeName]];
    return qName;
  } else {
    return [NSMutableString stringWithUTF8String:metadata->typeName];
  }
}

NSString *JreClassQualifiedName(const J2ObjcClassInfo *metadata) {
  return BuildQualifiedName(metadata);
}
