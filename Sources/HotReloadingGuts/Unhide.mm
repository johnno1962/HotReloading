//
//  Unhide.mm
//
//  Created by John Holdsworth on 07/03/2021.
//
//  Removes "hidden" visibility for certain Swift symbols
//  (default argument generators) so they can be referenced
//  in a file being dynamically loaded.
//
//  $Id: //depot/HotReloading/Sources/HotReloadingGuts/Unhide.mm#2 $
//

#import <Foundation/Foundation.h>

#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach-o/stab.h>

#import <string>
#import <map>

extern "C" {
    #import "Unhide.h"
}

std::map<std::string,int> seen;

int unhide_symbols(const char *framework, const char *linkFileList, FILE *log) {
    FILE *linkFiles = fopen(linkFileList, "r");
    if (!linkFiles) {
       fprintf(log, "unhide: Could not open link file list %s\n", linkFileList);
       return -1;
    }

    char buffer[PATH_MAX];
    int totalExported = 0;

    while (fgets(buffer, sizeof buffer, linkFiles)) {
        buffer[strlen(buffer)-1] = '\000';

        @autoreleasepool {
            NSString *file = [NSString stringWithUTF8String:buffer];
            NSData *patched = [[NSMutableData alloc] initWithContentsOfFile:file];

            if (!patched) {
                fprintf(log, "unhide: Could not read %s\n", [file UTF8String]);
                continue;
            }

            struct mach_header_64 *object = (struct mach_header_64 *)[patched bytes];
            const char *filename = file.lastPathComponent.UTF8String;

            if (object->magic != MH_MAGIC_64) {
                fprintf(log, "unhide: Invalid magic 0x%x != 0x%x (bad arch?)\n",
                        object->magic, MH_MAGIC_64);
                continue;
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
                continue;
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
                const char *symname = (char *)object + symtab->stroff + symbol.n_un.n_strx, *symend;

//                printf("symbol: #%d 0%lo 0x%x 0x%x %3d %s\n", i,
//                       (char *)&symbol.n_type - (char *)object,
//                       symbol.n_type, symbol.n_desc,
//                       symbol.n_sect, symname);
                if (strncmp(symname, "_$s", 3) != 0)
                    continue; // not swift symbol

                // Default argument generators have a suffix ANN_
                symend = symname + strlen(symname);
                BOOL isDefaultArgument = (symend[-1] == '_' &&
                   (symend[-2] == 'A' || (symend[-3] == 'A' && isdigit(symend[-2])) ||
                    (symend[-4] == 'A' && isdigit(symend[-3]) && isdigit(symend[-2])))) ||
                    strcmp(symend-4, "QOMg") == 0 || strcmp(symend-3, "vau") == 0;

                // The following reads: If symbol is for a default argument
                // and it is the definition (not a reference) and we've not
                // seen it before and it hadsn't already been "unhidden"...
                if (isDefaultArgument && symbol.n_sect != NO_SECT &&
                    !seen[symname]++ && symbol.n_type & N_PEXT) {
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

            if (exported && ![patched writeToFile:file atomically:NO])
                fprintf(log, "unhide: Could not write %s\n", [file UTF8String]);
            totalExported += exported;
        }
    }

    fclose(linkFiles);
    return totalExported;
}
