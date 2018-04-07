#include <objc/runtime.h>
#include <objc/message.h>
#include <pthread.h>

#include <getopt.h> // getopt_long()
#include <libgen.h> // basename()

#import <UIKit/UIPasteboard.h>
#import <MobileCoreServices/MobileCoreServices.h>

//#include <unistd.h>
//#include <sys/syslimits.h> // PATH_MAX
//#include <fcntl.h> // fcntl()

#define _LOGX {fprintf(stderr, "XXX passing line %d %s\n", __LINE__, __PRETTY_FUNCTION__);}
#if 01
#define LOGX _LOGX
#else
#define LOGX
#endif

// UIKit fixes
// kUIKitTypeColor doesn't actually exist but we make it to be consistent and use constants.
NSString * const kUIKitTypeColor = @"com.apple.uikit.color";
// kUIKitTypeImage is not linkable so we have to reproduce it.
NSString * const kUIKitTypeImage = @"com.apple.uikit.image";

// Apple decided to call the unsymbolicated function `_UIPasteboardInitialize` from within `UIApplicationMain` instead of calling it from `UIPasteboard`'s +load or +initialize. Therefore we have to make it ourselves for UIPasteboard to work (namely the fast accessors .string/s, .image/s, .url/s and .color/s).
__attribute__((constructor))
void _UIPasteboardInitialize() {
	UIPasteboardTypeListString = [NSArray arrayWithObjects: (id)kUTTypeUTF8PlainText, (id)kUTTypeText, nil];
	UIPasteboardTypeListURL    = [NSArray arrayWithObjects: (id)kUTTypeURL, nil];
	UIPasteboardTypeListImage  = [NSArray arrayWithObjects: (id)kUTTypePNG, (id)kUTTypeTIFF, (id)kUTTypeJPEG, (id)kUTTypeGIF, kUIKitTypeImage, nil];
	UIPasteboardTypeListColor  = [NSArray arrayWithObjects: kUIKitTypeColor, nil];
}

NSString * const kPBPrivateTypeDefault = @"private.default";

typedef NS_ENUM(NSUInteger, PBPasteboardMode) {
	PBPasteboardModeNoop,
	PBPasteboardModeCopy,
	PBPasteboardModePaste,
};

typedef NS_ENUM(NSUInteger, PBPasteboardType) {
	PBPasteboardTypeDefault,
	PBPasteboardTypeString,
	PBPasteboardTypeURL,
	PBPasteboardTypeImage,
	PBPasteboardTypeColor,
};

static NSArray const * types = nil;
static void PBPasteboardOnce(void) {
	types = [NSArray arrayWithObjects:
			kPBPrivateTypeDefault,
			(id)kUTTypeText,
			(id)kUTTypeURL,
			(id)kUTTypePNG,
			kUIKitTypeColor,
			nil
		];
}

const char * PBPasteboardTypeGetStringFromType(PBPasteboardType type) {
	pthread_once_t once = PTHREAD_ONCE_INIT;
	pthread_once(&once, &PBPasteboardOnce);
	return ((NSString *)types[type]).UTF8String;
}

static char * filePathFromFd(int fd) {
	char * path = NULL;
	char filePath[PATH_MAX];
	if (fcntl(fd, F_GETPATH, filePath) != -1) {
		path = strdup(filePath);
	}
	return path;
}

NSString * PBCreateFilePathFromFd(int fd) {
	char * filePath = filePathFromFd(fd);
	if (!filePath) {
		return nil;
	}
	NSString * string = [[NSString alloc] initWithUTF8String:filePath];
	free(filePath);
	return string;
}

NSString * PBCreateUTIStringFromFilePath(NSString * filePath) {
	if (!filePath) {
		return nil;
	}
	return (NSString *)UTTypeCreatePreferredIdentifierForTag(
		kUTTagClassFilenameExtension,
		(CFStringRef)filePath.pathExtension,
		NULL);
}

PBPasteboardType PBPasteboardTypeOfFd(int fd) {
	@autoreleasepool {
		NSString * path = PBCreateFilePathFromFd(fd);
		//fprintf(stderr, "Path %s\n", path.UTF8String);
		NSString * UTI = PBCreateUTIStringFromFilePath(path);
		//fprintf(stderr, "UTI %s\n", UTI.UTF8String);
		[path release];

		NSArray * typesArray = [NSArray arrayWithObjects:
			[NSArray arrayWithObjects: kPBPrivateTypeDefault, nil],
			UIPasteboardTypeListString,
			UIPasteboardTypeListURL,
			UIPasteboardTypeListImage,
			UIPasteboardTypeListColor,
			nil
		];
		NSUInteger index = 0;
		for (NSArray * types in typesArray) {
			if ([types containsObject:UTI]) {
				index = [typesArray indexOfObject:types];
				break;
			}
		}
		[UTI release];
		return (PBPasteboardType)index;
	}
}

char * PBCreateBufferFromFd(int fd, size_t * length) {
	FILE * file = fdopen(fd, "r");
	char c;
	size_t p4kB = 4096, i = 0;
	void * newPtr = NULL;
	char * buffer = (char *)malloc(p4kB * sizeof(char));

	while (buffer != NULL && (fscanf(file, "%c", &c) != EOF)) {
		if (i == p4kB * sizeof(char)) {
			p4kB += 4096;
			if ((newPtr = realloc(buffer, p4kB * sizeof(char))) != NULL) {
				buffer = (char *)newPtr;
			} else {
				free(buffer);
				i = 0;
				buffer = NULL;
				break;
			}
		}
		buffer[i++] = c;
	}

	if (buffer != NULL) {
		if ((newPtr = realloc(buffer, (i + 1) * sizeof(char))) != NULL) {
			buffer = (char *)newPtr;
			buffer[i] = '\0';
		} else {
			free(buffer);
			i = 0;
			buffer = NULL;
		}
	}

	if (length) {
		*length = i;
	}
	return buffer;
}

char * PBPasteboardSaveImage(UIImage * image, char * path, size_t * lengthPtr) {
	if (!image) {
		return NULL;
	}

	NSString * ext = @(path).pathExtension;
	NSArray * supportedExtensions = [NSArray arrayWithObjects:
		@"png",
		@"jpg",
		nil
	];

	BOOL success = NO;
	NSURL * fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"com.uikit.pasteboard.buffer"]];
	NSError * error = nil;
	NSData * data = nil;

	switch ([supportedExtensions indexOfObject:ext]) {
		case 0: {
			data = UIImagePNGRepresentation(image);
		} break;

		case 1: {
			data = UIImageJPEGRepresentation(image, 1.0);
		} break;
		default: {
			fprintf(stderr,
				"Extension '%s' not supported.\n"
				, ext.UTF8String
			);
		} break;
	}

	if (data) {
		if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&error]) {
			fprintf(stderr, "Error <%s>.\n", error.description.UTF8String);
			return NULL;
		}
		success = YES;
	}

	char * buffer = NULL;
	if (success) {
		int fd = open(fileURL.path.UTF8String, O_RDONLY);
		size_t length = 0;
		buffer = PBCreateBufferFromFd(fd, &length);
		close(fd);
		[NSFileManager.defaultManager removeItemAtURL:fileURL error:&error];
		if (length > 0) {
			*lengthPtr = length;
		}
	}
	return buffer;
}

void PBPasteboardPerformCopy(int fd, PBPasteboardType overrideType) {
	PBPasteboardType inType = (overrideType != PBPasteboardTypeDefault) ? overrideType : PBPasteboardTypeOfFd(fd);

	UIPasteboard * generalPb = UIPasteboard.generalPasteboard;

	//const char * inTypeString = PBPasteboardTypeGetStringFromType(inType);
	//fprintf(stderr, "copy: Resource type <%s>.\n", inTypeString);

	switch (inType) {
		default: {
			NSString * path = PBCreateFilePathFromFd(fd);
			NSString * actualUTI = PBCreateUTIStringFromFilePath(path);
			[path release];
			//fprintf(stderr, "copy: Resource type <%s> unsupported. Performing default action.\n", actualUTI.UTF8String);
			[actualUTI release];
		}
		case PBPasteboardTypeString: {
			size_t length = 0;
			char * string = PBCreateBufferFromFd(fd, &length);
			if (length < 1) {
				break;
			}
			NSString * dataString = [NSString stringWithUTF8String:string];
			free(string);
			generalPb.string = dataString;
		} break;

		case PBPasteboardTypeImage: {
			char * path = filePathFromFd(fd);
			UIImage * image = [UIImage imageWithContentsOfFile:@(path)];
			generalPb.image = image;
			free(path);
		} break;
	}
}

void PBPasteboardPerformPaste(int fd, PBPasteboardType overrideType) {
	PBPasteboardType outType = (overrideType != PBPasteboardTypeDefault) ? overrideType : PBPasteboardTypeOfFd(fd);

	UIPasteboard * generalPb = UIPasteboard.generalPasteboard;

	//const char * outTypeString = PBPasteboardTypeGetStringFromType(outType);
	//fprintf(stderr, "paste: Resource type <%s>.\n", outTypeString);

	switch (outType) {
		default: {
			NSString * path = PBCreateFilePathFromFd(fd);
			NSString * actualUTI = PBCreateUTIStringFromFilePath(path);
			[path release];
			//fprintf(stderr, "paste: Resource type <%s> unsupported. Performing default action.\n", actualUTI.UTF8String);
			[actualUTI release];
		}
		case PBPasteboardTypeString: {
			if (generalPb.string) {
				dprintf(fd, "%s", generalPb.string.UTF8String);
			} else {
				dprintf(fd, "\n");
			}
		} break;

		case PBPasteboardTypeImage: {
			char * path = filePathFromFd(fd);
			size_t length = 0;
			char * raw = PBPasteboardSaveImage(generalPb.image, path, &length);
			if (!raw) {
				fprintf(stderr, "No buffer.\n");
				break;
			}
			write(fd, raw, length);
			free(path);
		} break;
	}

}

void PBPasteboardPrintHelp(int argc, char **argv, char **envp) {
	fprintf(stderr,
		"Usage: %s [OPTION]\n"
		"\n"
		"Overview: copy and paste items to the global pasteboard. Supports piping in and out as well as to files. It will try to automatically determine the file type based on the file extension and use the according pasteboard value.\n"
		"Currently supported extensions:\n"
		"  txt -> string\n"
		"  jpg, png -> image\n"
		"\n"
		"Options:\n"
		"  -h,--help      Print this help.\n"
		"  -s,--string    Force type to be the string value if available.\n"
		"  -u,--url       Force type to be the URL value if available.\n"
		"  -i,--image     Force type to be the image value if available.\n"
		"  -c,--color     Force type to be the color value if available.\n"
		, basename(argv[0])
	);
}

int main(int argc, char **argv, char **envp) {
	@autoreleasepool {
		int help_flag = 0;
		PBPasteboardType overrideType = PBPasteboardTypeDefault;

		// Process options
		struct option long_options[] = {
			{ "help",   no_argument, NULL, 'h' },
			{ "string", no_argument, NULL, 's' },
			{ "url",    no_argument, NULL, 'u' },
			{ "image",  no_argument, NULL, 'i' },
			{ "color",  no_argument, NULL, 'c' },
			/* End of options. */
			{ 0, 0, 0, 0 }
		};

		int opt;
		int option_index = 0;
		while ((opt = getopt_long(argc, argv, "hsuic", long_options, &option_index)) != -1) {
			switch (opt) {
			case 's':
				if (overrideType == PBPasteboardTypeDefault) {
					overrideType = PBPasteboardTypeString;
				} else {
					fprintf(stderr, "Cannot set multiple pasteboard types.\n");
				}
				break;

			case 'u':
				if (overrideType == PBPasteboardTypeDefault) {
					overrideType = PBPasteboardTypeURL;
				} else {
					fprintf(stderr, "Cannot set multiple pasteboard types.\n");
				}
				break;

			case 'i':
				if (overrideType == PBPasteboardTypeDefault) {
					overrideType = PBPasteboardTypeImage;
				} else {
					fprintf(stderr, "Cannot set multiple pasteboard types.\n");
				}
				break;

			case 'c':
				if (overrideType == PBPasteboardTypeDefault) {
					overrideType = PBPasteboardTypeColor;
				} else {
					fprintf(stderr, "Cannot set multiple pasteboard types.\n");
				}
				break;

			default:
			case 'h':
				help_flag = 1;
				break;
			}
		}

		if (help_flag) {
			PBPasteboardPrintHelp(argc, argv, envp);
			return 0;
		}

		int inFD = STDIN_FILENO;
		int outFD = STDOUT_FILENO;

		PBPasteboardMode mode =
			isatty(inFD) ? PBPasteboardModePaste :
			isatty(outFD) ? PBPasteboardModeCopy :
			PBPasteboardModeCopy | PBPasteboardModePaste;

		if (mode & PBPasteboardModeCopy) {
			PBPasteboardPerformCopy(inFD, overrideType);
		}

		if (mode & PBPasteboardModePaste) {
			PBPasteboardPerformPaste(outFD, overrideType);
		}
	}
	return 0;
}

// vim:ft=objc
