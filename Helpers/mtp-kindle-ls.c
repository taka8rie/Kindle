#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#include <libmtp.h>

static void print_escaped(const char *text) {
    if (text == NULL) {
        return;
    }

    for (const unsigned char *p = (const unsigned char *)text; *p; p++) {
        switch (*p) {
        case '\\':
            fputs("\\\\", stdout);
            break;
        case '\t':
            fputs("\\t", stdout);
            break;
        case '\n':
            fputs("\\n", stdout);
            break;
        case '\r':
            fputs("\\r", stdout);
            break;
        default:
            fputc(*p, stdout);
            break;
        }
    }
}

static void print_error(const char *code, const char *message) {
    fputs("ERROR\t", stdout);
    print_escaped(code);
    fputc('\t', stdout);
    print_escaped(message);
    fputc('\n', stdout);
}

static char *unescape_field(const char *text) {
    size_t len = strlen(text);
    char *out = malloc(len + 1);
    if (out == NULL) {
        return NULL;
    }

    char *dst = out;
    for (const char *src = text; *src; src++) {
        if (*src != '\\') {
            *dst++ = *src;
            continue;
        }

        src++;
        if (*src == '\0') {
            *dst++ = '\\';
            break;
        }

        switch (*src) {
        case 't':
            *dst++ = '\t';
            break;
        case 'n':
            *dst++ = '\n';
            break;
        case 'r':
            *dst++ = '\r';
            break;
        case '\\':
            *dst++ = '\\';
            break;
        default:
            *dst++ = *src;
            break;
        }
    }
    *dst = '\0';
    return out;
}

static char *join_path(const char *parent, const char *name) {
    if (name == NULL) {
        name = "";
    }

    if (parent == NULL || parent[0] == '\0' || strcmp(parent, "/") == 0) {
        size_t size = strlen(name) + 2;
        char *path = malloc(size);
        if (path == NULL) {
            return NULL;
        }
        snprintf(path, size, "/%s", name);
        return path;
    }

    size_t size = strlen(parent) + strlen(name) + 2;
    char *path = malloc(size);
    if (path == NULL) {
        return NULL;
    }
    snprintf(path, size, "%s/%s", parent, name);
    return path;
}

static void print_item(LIBMTP_file_t *file, uint32_t storage_id, const char *path) {
    const int is_folder = file->filetype == LIBMTP_FILETYPE_FOLDER;
    const char *type = LIBMTP_Get_Filetype_Description(file->filetype);

    fputs("ITEM\t", stdout);
    fputs(is_folder ? "folder" : "file", stdout);
    fprintf(stdout, "\t%u\t%u\t%u\t", file->item_id, file->parent_id, storage_id);
    if (!is_folder) {
        fprintf(stdout, "%llu", (unsigned long long)file->filesize);
    }
    fputc('\t', stdout);
    print_escaped(path);
    fputc('\t', stdout);
    print_escaped(file->filename);
    fputc('\t', stdout);
    print_escaped(type);
    fputc('\n', stdout);
}

static int list_children(LIBMTP_mtpdevice_t *device, uint32_t storage_id, uint32_t parent_id, const char *parent_path) {
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(device, storage_id, parent_id);
    if (files == NULL) {
        LIBMTP_Clear_Errorstack(device);
        return 0;
    }

    int count = 0;
    LIBMTP_file_t *file = files;
    while (file != NULL) {
        LIBMTP_file_t *next = file->next;
        char *path = join_path(parent_path, file->filename);

        if (path != NULL) {
            print_item(file, storage_id, path);
            count++;
            if (file->filetype == LIBMTP_FILETYPE_FOLDER) {
                count += list_children(device, storage_id, file->item_id, path);
            }
            free(path);
        }

        LIBMTP_destroy_file_t(file);
        file = next;
    }

    return count;
}

static int list_device(LIBMTP_mtpdevice_t *device) {
    int total_items = 0;

    if (LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0) {
        LIBMTP_Clear_Errorstack(device);
    }

    puts("BEGIN_LIST");
    for (LIBMTP_devicestorage_t *storage = device->storage; storage != NULL; storage = storage->next) {
        fputs("STORAGE\t", stdout);
        fprintf(stdout, "%u\t", storage->id);
        print_escaped(storage->StorageDescription);
        fprintf(stdout, "\t%llu\t%llu\n",
                (unsigned long long)storage->MaxCapacity,
                (unsigned long long)storage->FreeSpaceInBytes);
        total_items += list_children(device, storage->id, LIBMTP_FILES_AND_FOLDERS_ROOT, "");
    }
    fprintf(stdout, "END_LIST\t%d\n", total_items);
    fflush(stdout);
    return total_items;
}

static LIBMTP_filetype_t filetype_for_path(const char *path) {
    const char *ext = strrchr(path, '.');
    if (ext == NULL) {
        return LIBMTP_FILETYPE_UNKNOWN;
    }
    ext++;

    if (strcasecmp(ext, "txt") == 0) return LIBMTP_FILETYPE_TEXT;
    if (strcasecmp(ext, "html") == 0 || strcasecmp(ext, "htm") == 0) return LIBMTP_FILETYPE_HTML;
    if (strcasecmp(ext, "pdf") == 0) return LIBMTP_FILETYPE_DOC;
    if (strcasecmp(ext, "xml") == 0) return LIBMTP_FILETYPE_XML;
    if (strcasecmp(ext, "jpg") == 0 || strcasecmp(ext, "jpeg") == 0) return LIBMTP_FILETYPE_JPEG;
    if (strcasecmp(ext, "png") == 0) return LIBMTP_FILETYPE_PNG;
    return LIBMTP_FILETYPE_UNKNOWN;
}

static char **split_path(const char *path, int *count) {
    *count = 0;
    char *copy = strdup(path);
    if (copy == NULL) {
        return NULL;
    }

    int capacity = 8;
    char **parts = calloc((size_t)capacity, sizeof(char *));
    if (parts == NULL) {
        free(copy);
        return NULL;
    }

    char *saveptr = NULL;
    for (char *token = strtok_r(copy, "/", &saveptr); token != NULL; token = strtok_r(NULL, "/", &saveptr)) {
        if (*token == '\0') {
            continue;
        }
        if (*count >= capacity) {
            capacity *= 2;
            char **grown = realloc(parts, (size_t)capacity * sizeof(char *));
            if (grown == NULL) {
                break;
            }
            parts = grown;
        }
        parts[*count] = strdup(token);
        if (parts[*count] != NULL) {
            (*count)++;
        }
    }

    free(copy);
    return parts;
}

static void free_path_parts(char **parts, int count) {
    if (parts == NULL) {
        return;
    }
    for (int i = 0; i < count; i++) {
        free(parts[i]);
    }
    free(parts);
}

static uint32_t find_folder_child(LIBMTP_mtpdevice_t *device, uint32_t storage_id, uint32_t parent_id, const char *name) {
    LIBMTP_file_t *files = LIBMTP_Get_Files_And_Folders(device, storage_id, parent_id);
    if (files == NULL) {
        LIBMTP_Clear_Errorstack(device);
        return 0;
    }

    uint32_t found = 0;
    LIBMTP_file_t *file = files;
    while (file != NULL) {
        LIBMTP_file_t *next = file->next;
        if (found == 0 && file->filetype == LIBMTP_FILETYPE_FOLDER && file->filename != NULL && strcasecmp(file->filename, name) == 0) {
            found = file->item_id;
        }
        LIBMTP_destroy_file_t(file);
        file = next;
    }

    return found;
}

static uint32_t ensure_folder_path(LIBMTP_mtpdevice_t *device, uint32_t storage_id, const char *path) {
    int count = 0;
    char **parts = split_path(path, &count);
    if (parts == NULL) {
        return 0;
    }

    uint32_t parent = LIBMTP_FILES_AND_FOLDERS_ROOT;
    for (int i = 0; i < count; i++) {
        uint32_t child = find_folder_child(device, storage_id, parent, parts[i]);
        if (child == 0) {
            uint32_t create_parent = parent == LIBMTP_FILES_AND_FOLDERS_ROOT ? 0 : parent;
            child = LIBMTP_Create_Folder(device, parts[i], create_parent, storage_id);
            if (child == 0) {
                LIBMTP_Clear_Errorstack(device);
                parent = 0;
                break;
            }
        }
        parent = child;
    }

    free_path_parts(parts, count);
    return parent;
}

static void send_file_to_folder(LIBMTP_mtpdevice_t *device, const char *local_path, const char *folder_path) {
    if (device->storage == NULL) {
        if (LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0) {
            LIBMTP_Clear_Errorstack(device);
        }
    }

    LIBMTP_devicestorage_t *storage = device->storage;
    if (storage == NULL) {
        print_error("SEND_FAILED", "没有可写入的 Kindle 存储。");
        fflush(stdout);
        return;
    }

    uint32_t parent_id = ensure_folder_path(device, storage->id, folder_path);
    if (parent_id == 0) {
        print_error("SEND_FAILED", "找不到或无法创建目标文件夹。");
        fflush(stdout);
        return;
    }

    struct stat st;
    if (stat(local_path, &st) != 0) {
        print_error("SEND_FAILED", "无法读取本地文件。");
        fflush(stdout);
        return;
    }

    const char *filename = strrchr(local_path, '/');
    filename = filename == NULL ? local_path : filename + 1;

    LIBMTP_file_t *file = LIBMTP_new_file_t();
    if (file == NULL) {
        print_error("SEND_FAILED", "无法创建 MTP 文件对象。");
        fflush(stdout);
        return;
    }

    file->filename = strdup(filename);
    file->filesize = (uint64_t)st.st_size;
    file->parent_id = parent_id;
    file->storage_id = storage->id;
    file->filetype = filetype_for_path(local_path);

    int result = LIBMTP_Send_File_From_File(device, local_path, file, NULL, NULL);
    if (result != 0) {
        LIBMTP_Clear_Errorstack(device);
        LIBMTP_destroy_file_t(file);
        print_error("SEND_FAILED", "复制到 Kindle 失败。");
        fflush(stdout);
        return;
    }

    fputs("SEND_OK\t", stdout);
    print_escaped(local_path);
    fputc('\t', stdout);
    print_escaped(folder_path);
    fputc('\t', stdout);
    print_escaped(filename);
    fputc('\n', stdout);
    fflush(stdout);

    LIBMTP_destroy_file_t(file);
}

static int open_first_device(LIBMTP_mtpdevice_t **out_device, LIBMTP_raw_device_t **out_rawdevices) {
    LIBMTP_raw_device_t *rawdevices = NULL;
    int numrawdevices = 0;
    LIBMTP_error_number_t err = LIBMTP_Detect_Raw_Devices(&rawdevices, &numrawdevices);

    if (err == LIBMTP_ERROR_NO_DEVICE_ATTACHED) {
        print_error("NO_DEVICE", "没有检测到 MTP 设备。");
        return 2;
    }
    if (err != LIBMTP_ERROR_NONE) {
        print_error("DETECT_FAILED", "检测 MTP 设备失败。");
        return 3;
    }

    for (int i = 0; i < numrawdevices; i++) {
        LIBMTP_mtpdevice_t *device = LIBMTP_Open_Raw_Device_Uncached(&rawdevices[i]);
        if (device != NULL) {
            LIBMTP_Clear_Errorstack(device);
            *out_device = device;
            *out_rawdevices = rawdevices;
            return 0;
        }
    }

    LIBMTP_FreeMemory(rawdevices);
    print_error("OPEN_FAILED", "无法打开 Kindle 的 MTP 会话。");
    return 4;
}

static int run_agent(void) {
    LIBMTP_mtpdevice_t *device = NULL;
    LIBMTP_raw_device_t *rawdevices = NULL;
    int status;

    puts("KINDLEAGENT\t1");
    LIBMTP_Init();

    status = open_first_device(&device, &rawdevices);
    if (status != 0) {
        fflush(stdout);
        return status;
    }

    puts("READY");
    fflush(stdout);

    char *line = NULL;
    size_t linecap = 0;
    while (getline(&line, &linecap, stdin) > 0) {
        line[strcspn(line, "\r\n")] = '\0';

        if (strcmp(line, "QUIT") == 0) {
            puts("BYE");
            fflush(stdout);
            break;
        }

        if (strcmp(line, "LIST") == 0) {
            list_device(device);
            continue;
        }

        if (strncmp(line, "SEND\t", 5) == 0) {
            char *local = line + 5;
            char *folder = strchr(local, '\t');
            if (folder == NULL) {
                print_error("BAD_COMMAND", "SEND 命令缺少目标文件夹。");
                fflush(stdout);
                continue;
            }
            *folder++ = '\0';

            char *local_path = unescape_field(local);
            char *folder_path = unescape_field(folder);
            if (local_path == NULL || folder_path == NULL) {
                print_error("BAD_COMMAND", "SEND 命令解析失败。");
                fflush(stdout);
            } else {
                send_file_to_folder(device, local_path, folder_path);
            }
            free(local_path);
            free(folder_path);
            continue;
        }

        print_error("BAD_COMMAND", "未知命令。");
        fflush(stdout);
    }

    free(line);
    LIBMTP_Release_Device(device);
    LIBMTP_FreeMemory(rawdevices);
    return 0;
}

int main(int argc, char **argv) {
    LIBMTP_raw_device_t *rawdevices = NULL;
    int numrawdevices = 0;
    LIBMTP_error_number_t err;

    if (argc > 1 && strcmp(argv[1], "--agent") == 0) {
        return run_agent();
    }

    puts("KINDLELS\t1");
    LIBMTP_Init();

    err = LIBMTP_Detect_Raw_Devices(&rawdevices, &numrawdevices);
    if (err == LIBMTP_ERROR_NO_DEVICE_ATTACHED) {
        print_error("NO_DEVICE", "没有检测到 MTP 设备。");
        return 2;
    }
    if (err != LIBMTP_ERROR_NONE) {
        print_error("DETECT_FAILED", "检测 MTP 设备失败。");
        return 3;
    }

    int total_items = 0;
    int opened_devices = 0;
    for (int i = 0; i < numrawdevices; i++) {
        LIBMTP_mtpdevice_t *device = LIBMTP_Open_Raw_Device_Uncached(&rawdevices[i]);
        if (device == NULL) {
            print_error("OPEN_FAILED", "无法打开 Kindle 的 MTP 文件列表。");
            continue;
        }

        opened_devices++;
        LIBMTP_Clear_Errorstack(device);

        if (LIBMTP_Get_Storage(device, LIBMTP_STORAGE_SORTBY_NOTSORTED) != 0) {
            LIBMTP_Clear_Errorstack(device);
        }

        for (LIBMTP_devicestorage_t *storage = device->storage; storage != NULL; storage = storage->next) {
            fputs("STORAGE\t", stdout);
            fprintf(stdout, "%u\t", storage->id);
            print_escaped(storage->StorageDescription);
            fprintf(stdout, "\t%llu\t%llu\n",
                    (unsigned long long)storage->MaxCapacity,
                    (unsigned long long)storage->FreeSpaceInBytes);
            total_items += list_children(device, storage->id, LIBMTP_FILES_AND_FOLDERS_ROOT, "");
        }

        LIBMTP_Release_Device(device);
    }

    LIBMTP_FreeMemory(rawdevices);

    if (opened_devices == 0) {
        return 4;
    }

    fprintf(stdout, "OK\t%d\n", total_items);
    return 0;
}
