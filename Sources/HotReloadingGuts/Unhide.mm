//
//  Unhide.mm
//
//  Created by John Holdsworth on 07/03/2021.
//
//  Removes "hidden" visibility for certain Swift symbols
//  (default argument generators) so they can be referenced
//  in a file being dynamically loaded.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/Unhide.mm#32 $
//

#import <Foundation/Foundation.h>

#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach-o/stab.h>
#import <sys/stat.h>
#import <string>
#import <map>

extern "C" {
    #import "InjectionClient.h"
}

static std::map<std::string,int> seen;

static const char *strend(const char *str) {
    return str + strlen(str);
}

void unhide_reset(void) {
    seen.clear();
}

int unhide_symbols(const char *framework, const char *linkFileList, FILE *log, time_t since) {
    FILE *linkFiles = fopen(linkFileList, "r");
    if (!linkFiles) {
       fprintf(log, "unhide: Could not open link file list %s\n", linkFileList);
       return -1;
    }

    char buffer[PATH_MAX];
    __block int totalExported = 0;

    while (fgets(buffer, sizeof buffer, linkFiles)) {
        buffer[strlen(buffer)-1] = '\000';
        @autoreleasepool {
            totalExported += unhide_object(buffer, framework, log, nil, nil);
        }
    }

    fclose(linkFiles);
    return totalExported;
}

int unhide_object(const char *object_file, const char *framework, FILE *log,
                  NSMutableArray<NSString *> *class_references,
                  NSMutableArray<NSString *> *descriptor_refs) {
//            struct stat info;
//            if (stat(buffer, &info) || info.st_mtimespec.tv_sec < since)
//                continue;
            NSString *file = [NSString stringWithUTF8String:object_file];
            NSData *patched = [[NSMutableData alloc] initWithContentsOfFile:file];

            if (!patched) {
                fprintf(log, "unhide: Could not read %s\n", [file UTF8String]);
                return 0;
            }

            struct mach_header_64 *object = (struct mach_header_64 *)[patched bytes];
            const char *filename = file.lastPathComponent.UTF8String;

            if (object->magic != MH_MAGIC_64) {
                fprintf(log, "unhide: Invalid magic 0x%x != 0x%x (bad arch?)\n",
                        object->magic, MH_MAGIC_64);
                return 0;
            }

            struct symtab_command *symtab = NULL;
            struct dysymtab_command *dylib = NULL;

            for (struct load_command *cmd = (struct load_command *)((char *)object + sizeof *object) ;
                 cmd < (struct load_command *)((char *)object + object->sizeofcmds) ;
                 cmd = (struct load_command *)((char *)cmd + cmd->cmdsize)) {

                if (cmd->cmd == LC_SYMTAB)
                    symtab = (struct symtab_command *)cmd;
                else if (cmd->cmd == LC_DYSYMTAB)
                    dylib = (struct dysymtab_command *)cmd;
            }

            if (!symtab || !dylib) {
                fprintf(log, "unhide: Missing symtab or dylib cmd %s: %p & %p\n",
                        filename, symtab, dylib);
                return 0;
            }
            struct nlist_64 *all_symbols64 = (struct nlist_64 *)((char *)object + symtab->symoff);
#if 1
            struct nlist_64 *end_symbols64 = all_symbols64 + symtab->nsyms;
            int exported = 0;

//            dylib->iextdefsym -= dylib->nlocalsym;
//            dylib->nextdefsym += dylib->nlocalsym;
//            dylib->nlocalsym = 0;
#endif
            size_t isReverseInterpose = class_references ? strlen(framework) : 0;
            for (int i=0 ; i<symtab->nsyms ; i++) {
                struct nlist_64 &symbol = all_symbols64[i];
                if (symbol.n_sect == NO_SECT)
                    continue; // not definition
                const char *symname = (char *)object + symtab->stroff + symbol.n_un.n_strx;

                if (class_references) {
                    static char classRef[] = {"l_OBJC_CLASS_REF_$_"};
                    int clasRefSize = sizeof classRef-1;
                    if (strncmp(symname, classRef, clasRefSize) == 0)
                        [class_references addObject:[NSString
                         stringWithUTF8String:symname + clasRefSize]];
                }

                if (descriptor_refs) {
                    static char gotPrefix[] = {"l_got."};
                    int gotPrefixSize = sizeof gotPrefix-1;
                    if (strncmp(symname, gotPrefix, gotPrefixSize) == 0)
                        [descriptor_refs addObject:[NSString
                         stringWithUTF8String:symname + gotPrefixSize]];
                }

                if (strncmp(symname, "_$s", 3) != 0)
                    continue; // not swift symbol

                // Default argument generators have a suffix ANN_
                // Covers a few other cases encountred now as well.
                const char *symend = strend(symname) - 1;
                BOOL isMutableAddressor = strcmp(symend-2, "vau") == 0 ||
                    // witness table accessor functions...
                    (strcmp(symend-1, "Wl") == 0 &&
                     strncmp(symname+1, framework, isReverseInterpose) == 0);
                BOOL isDefaultArgument = (*symend == '_' &&
                    (symend[-1] == 'A' || (isdigit(symend[-1]) &&
                    (symend[-2] == 'A' || (isdigit(symend[-2]) &&
                     symend[-3] == 'A'))))) ||// isMutableAddressor ||
                    strcmp(symend-1, "FZ") == 0 || (symend[-1] == 'M' && (
                    *symend == 'c' || *symend == 'g' || *symend == 'n'));

//                fprintf(log, "symbol: #%d 0%lo 0x%x 0x%x %3d %s %d\n",
//                       i, (char *)&symbol.n_type - (char *)object,
//                       symbol.n_type, symbol.n_desc,
//                       symbol.n_sect, symname, isDefaultArgument);

                // The following reads: If symbol is for a default argument
                // and it is the definition (not a reference) and we've not
                // seen it before and it hadsn't already been "unhidden"...
                if (isReverseInterpose ? isMutableAddressor :
                    isDefaultArgument && !seen[symname]++ &&
                    symbol.n_type & N_PEXT) {
                    symbol.n_type |= N_EXT;
                    symbol.n_type &= ~N_PEXT;
                    symbol.n_type = 0xf;
                    symbol.n_desc = N_GSYM;

                    if (!exported++)
                        fprintf(log, "%s.%s: local: %d %d ext: %d %d undef: %d %d extref: %d %d indirect: %d %d extrel: %d %d localrel: %d %d symlen: 0%lo\n",
                               framework, filename,
                               dylib->ilocalsym, dylib->nlocalsym,
                               dylib->iextdefsym, dylib->nextdefsym,
                               dylib->iundefsym, dylib->nundefsym,
                               dylib->extrefsymoff, dylib->nextrefsyms,
                               dylib->indirectsymoff, dylib->nindirectsyms,
                               dylib->extreloff, dylib->nextrel,
                               dylib->locreloff, dylib->nlocrel,
                               (char *)&end_symbols64->n_un - (char *)object);

                    fprintf(log, "exported: #%d 0%lo 0x%x 0x%x %3d %s\n", i,
                           (char *)&symbol.n_type - (char *)object,
                           symbol.n_type, symbol.n_desc,
                           symbol.n_sect, symname);
                }
            }

            if (exported && ![patched writeToFile:file atomically:YES])
                fprintf(log, "unhide: Could not write %s\n", [file UTF8String]);
            return exported;
}

int unhide_framework(const char *framework, FILE *log) {
    int totalExported = 0;
#if 0 // Not implemented
    @autoreleasepool {
        NSString *file = [NSString stringWithUTF8String:framework];
        NSData *patched = [[NSMutableData alloc] initWithContentsOfFile:file];

        if (!patched) {
            fprintf(log, "unhide: Could not read %s\n", [file UTF8String]);
            return -1;
        }

        struct mach_header_64 *object = (struct mach_header_64 *)[patched bytes];
        const char *filename = file.lastPathComponent.UTF8String;

        if (object->magic != MH_MAGIC_64) {
            fprintf(log, "unhide: Invalid magic 0x%x != 0x%x (bad arch?)\n",
                    object->magic, MH_MAGIC_64);
            return -1;
        }

        struct symtab_command *symtab = NULL;
        struct dysymtab_command *dylib = NULL;

        for (struct load_command *cmd = (struct load_command *)((char *)object + sizeof *object) ;
             cmd < (struct load_command *)((char *)object + object->sizeofcmds) ;
             cmd = (struct load_command *)((char *)cmd + cmd->cmdsize)) {

            if (cmd->cmd == LC_SYMTAB)
                symtab = (struct symtab_command *)cmd;
            else if (cmd->cmd == LC_DYSYMTAB)
                dylib = (struct dysymtab_command *)cmd;
        }

        if (!symtab || !dylib) {
            fprintf(log, "unhide: Missing symtab or dylib cmd %s: %p & %p\n",
                    filename, symtab, dylib);
            return -1;
        }
        struct nlist_64 *all_symbols64 = (struct nlist_64 *)((char *)object + symtab->symoff);
#if 1
        struct nlist_64 *end_symbols64 = all_symbols64 + symtab->nsyms;
        int exported = 0;

//            dylib->iextdefsym -= dylib->nlocalsym;
//            dylib->nextdefsym += dylib->nlocalsym;
//            dylib->nlocalsym = 0;
#endif
        for (int i=0 ; i<symtab->nsyms ; i++) {
            struct nlist_64 &symbol = all_symbols64[i];
            if (symbol.n_sect == NO_SECT)
                continue; // not definition
            const char *symname = (char *)object + symtab->stroff + symbol.n_un.n_strx;

//                printf("symbol: #%d 0%lo 0x%x 0x%x %3d %s\n", i,
//                       (char *)&symbol.n_type - (char *)object,
//                       symbol.n_type, symbol.n_desc,
//                       symbol.n_sect, symname);
            if (strncmp(symname, "_$s", 3) != 0)
                continue; // not swift symbol

            // Default argument generators have a suffix ANN_
            // Covers a few other cases encountred now as well.
            const char *symend = strend(symname) - 1;
            BOOL isDefaultArgument = (*symend == '_' &&
                (symend[-1] == 'A' || (isdigit(symend[-1]) &&
                (symend[-2] == 'A' || (isdigit(symend[-2]) &&
                 symend[-3] == 'A'))))) || strcmp(symend-2, "vau") == 0 ||
                strcmp(symend-1, "FZ") == 0 || (symend[-1] == 'M' && (
                *symend == 'c' || *symend == 'g' || *symend == 'n'));

            // The following reads: If symbol is for a default argument
            // and it is the definition (not a reference) and we've not
            // seen it before and it hadsn't already been "unhidden"...
            if (isDefaultArgument && !seen[symname]++ &&
                symbol.n_type & N_PEXT) {
                symbol.n_type |= N_EXT;
                symbol.n_type &= ~N_PEXT;
                symbol.n_type = 0xf;
                symbol.n_desc = N_GSYM;

                if (!exported++)
                    fprintf(log, "%s.%s: local: %d %d ext: %d %d undef: %d %d extref: %d %d indirect: %d %d extrel: %d %d localrel: %d %d symlen: 0%lo\n",
                           framework, filename,
                           dylib->ilocalsym, dylib->nlocalsym,
                           dylib->iextdefsym, dylib->nextdefsym,
                           dylib->iundefsym, dylib->nundefsym,
                           dylib->extrefsymoff, dylib->nextrefsyms,
                           dylib->indirectsymoff, dylib->nindirectsyms,
                           dylib->extreloff, dylib->nextrel,
                           dylib->locreloff, dylib->nlocrel,
                           (char *)&end_symbols64->n_un - (char *)object);

                fprintf(log, "exported: #%d 0%lo 0x%x 0x%x %3d %s\n", i,
                       (char *)&symbol.n_type - (char *)object,
                       symbol.n_type, symbol.n_desc,
                       symbol.n_sect, symname);
            }
        }

        if (exported && ![patched writeToFile:file atomically:YES])
            fprintf(log, "unhide: Could not write %s\n", [file UTF8String]);
        totalExported += exported;
    }
#endif
    return totalExported;
}

#import <mach-o/getsect.h>
#import <mach/vm_param.h>
#import <sys/mman.h>
#import <dlfcn.h>

extern "C" {
    // Duplicated from SwiftTrace.h
    #define ST_LAST_IMAGE -1
    #define ST_ANY_VISIBILITY 0
    #define ST_GLOBAL_VISIBILITY 0xf
    #define ST_HIDDEN_VISIBILITY 0x1e
    #define ST_LOCAL_VISIBILITY 0xe

    typedef NS_ENUM(uint8_t, STVisibility) {
        STVisibilityAny = ST_ANY_VISIBILITY,
        STVisibilityGlobal = ST_GLOBAL_VISIBILITY,
        STVisibilityHidden = ST_HIDDEN_VISIBILITY,
        STVisibilityLocal = ST_LOCAL_VISIBILITY,
    };

    typedef BOOL (^ _Nonnull STSymbolFilter)(const char *_Nonnull symname);
    /**
     Callback on selecting symbol.
     */
    typedef void (^ _Nonnull STSymbolCallback)(const void *_Nonnull address, const char *_Nonnull symname,
                                         void *_Nonnull typeref, void *_Nonnull typeend);
    typedef void (*fast_dlscan_t)(const void *_Nonnull ptr,
        STVisibility visibility, STSymbolFilter filter, STSymbolCallback callback);
    typedef void *_Nullable (*fast_dlsym_t)(const void *_Nonnull ptr, const char *_Nonnull symname);
    typedef int (*fast_dladdr_t)(const void *_Nonnull, Dl_info *_Nonnull);
    typedef NSString *_Nonnull (*describeImageInfo_t)(const Dl_info *_Nonnull info);
}

void reverse_symbolics(const void *image) {
    #if TARGET_OS_IPHONE && !TARGET_IPHONE_SIMULATOR
    BOOL debug = FALSE;
    #define RSPREFIX "reverse_symbolics: ⚠️ "
    #define rsprintf if (debug) printf
    #define MAX_SYMBOLIC_REF 0x1f
    #define PAGE_ROUND(_sz) (((_sz) + PAGE_SIZE-1) & ~(PAGE_SIZE-1))
    #define LATE_BIND(f) static f##_t f; if (!f) f = (f##_t)dlsym(RTLD_DEFAULT, #f)
    LATE_BIND(fast_dlscan);
    LATE_BIND(fast_dladdr);
    LATE_BIND(describeImageInfo);

    uint64_t typeref_size = 0;
    char *typeref_start = getsectdatafromheader_64((mach_header_64 *)image,
                               SEG_TEXT, "__swift5_typeref", &typeref_size);
    if (mprotect((void *)((uintptr_t)typeref_start&~(PAGE_SIZE-1)),
                 PAGE_ROUND(typeref_size), PROT_WRITE|PROT_READ) != KERN_SUCCESS)
        printf(RSPREFIX"Unable to make %d bytes writable %s\n",
               (int)typeref_size, strerror(errno));

    static char symbolics[] = {"_symbolic _____"};
    fast_dlscan(image, STVisibilityAny, ^(const char *symname) {
        return strncmp(symname, symbolics, sizeof symbolics-1) == 0;
    }, ^(const void * _Nonnull address, const char * _Nonnull symname, void * _Nonnull typeref, void * _Nonnull typeend) {
//        rsprintf("%s\n", symname);

//        char buffer[1000], first[100];
//        const char *prefixPtr = symname + sizeof symbolics - 2;
//        const char *typesPtr = strchr(prefixPtr, ' ')+1;
        unsigned char *infoPtr = (unsigned char *)address;

        while (*infoPtr) {
            if (*infoPtr++ > MAX_SYMBOLIC_REF) {
                printf(RSPREFIX"Out of sync?\n");
                break;
            }

//            const char *typeEnd = strchr(typesPtr, ' ') ?:
//                                typesPtr + strlen(typesPtr);
//            snprintf(buffer, sizeof buffer, "$s%.*sMn",
//                     (int)(typeEnd - typesPtr), typesPtr);

            int before = *(int *)infoPtr;
            const void *referenced = infoPtr + before, *value;
            Dl_info info;

            if (fast_dladdr(referenced, &info) && info.dli_fbase == image &&
                strcmp(strend(info.dli_sname) - 2, "Mn") == 0 &&
                (value = dlsym(RTLD_DEFAULT, info.dli_sname))) {
                ssize_t relative = (unsigned char *)value - infoPtr;
                *(int *)infoPtr = (int)relative;
            }

            if (before != *(int *)infoPtr)
                rsprintf("Reversed: %x -> %x %s\n", before, *(int *)infoPtr,
                         describeImageInfo(&info).UTF8String);

            infoPtr += sizeof before;
            while (*infoPtr > MAX_SYMBOLIC_REF)
                infoPtr++;

//            static char delim[] = {"_____"};
//            while (strncmp(prefixPtr, delim, sizeof delim-1) != 0)
//                prefixPtr++;
//            prefixPtr += sizeof delim-1;
//
//            typesPtr = typeEnd;
//            if (*typesPtr == ' ')
//                typesPtr++;
//            else
//                break;
        }
    });

    #if 000
    static char associateds[] = {"_associated conformance "};
    fast_dlscan(image, STVisibilityAny, ^(const char *symname) {
        return strncmp(symname, associateds, sizeof associateds-1) == 0;
    }, ^(const void * _Nonnull address, const char * _Nonnull symname, void * _Nonnull typeref, void * _Nonnull typeend) {
        unsigned char *infoPtr = (unsigned char *)address;
        infoPtr += 2;

        void *ptr = infoPtr + *(int *)infoPtr;
        Dl_info info;
        fast_dladdr(ptr, &info);
        printf("ASSOC %s\n", describeImageInfo(&info).UTF8String);

        int v0 = *(int *)infoPtr;
        if (image == info.dli_fbase) {
            extern int main();
            void *value = fast_dlsym((void *)main, info.dli_sname);
            printf(">>>> %s %p %p %p\n",
                   info.dli_sname, image, info.dli_fbase, value);
            size_t diff = (unsigned char *)value - infoPtr;
            *(int *)infoPtr = (int)diff;
        }
        printf("%p -> %p %s\n", v0, *(int *)infoPtr,
               describeImageInfo(&info).UTF8String);
    });
    #endif

    if (mprotect((void *)((uintptr_t)typeref_start&~(PAGE_SIZE-1)),
                 PAGE_ROUND(typeref_size), PROT_EXEC|PROT_READ) != KERN_SUCCESS)
        printf(RSPREFIX"Unable to make %d bytes executable %s\n",
               (int)typeref_size, strerror(errno));
    #endif
}
