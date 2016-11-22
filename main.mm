#import <UIKit/UIPasteboard.h>
#import <MobileCoreServices/MobileCoreServices.h>

//#include <unistd.h>
//#include <sys/syslimits.h> // PATH_MAX
//#include <fcntl.h> // fcntl

#include <dispatch/dispatch.h>
#include <objc/runtime.h>
#include <objc/message.h>

// UIKit fixes
// kUIKitTypeColor doesn't actually exist but we make it to be consistent and use constants.
NSString * const kUIKitTypeColor = @"com.apple.uikit.color";
// kUIKitTypeImage is not linkable so we have to reproduce it.
NSString * const kUIKitTypeImage = @"com.apple.uikit.image";

// Apple decided to call the unsymbolicated function `_UIPasteboardInitialize` from within `UIApplicationMain` instead of calling it from `UIPasteboard`'s +load or +initialize. Therefore we have to make it ourselves for UIPasteboard to work (namely the fast accessors .string/s, .image/s, .url/s and .color/s).
__attribute__((constructor))
void _UIPasteboardInitialize() {
	UIPasteboardTypeListString = [[NSArray alloc] initWithObjects:(id)kUTTypeUTF8PlainText, (id)kUTTypeText, nil];
	UIPasteboardTypeListURL    = [[NSArray alloc] initWithObjects:(id)kUTTypeURL, nil];
	UIPasteboardTypeListColor  = [[NSArray alloc] initWithObjects:kUIKitTypeColor, nil];
	UIPasteboardTypeListImage  = [[NSArray alloc] initWithObjects:(id)kUTTypePNG, (id)kUTTypeTIFF, (id)kUTTypeJPEG, (id)kUTTypeGIF, kUIKitTypeImage, nil];
}

typedef NS_ENUM(NSUInteger, PBUIPasteboardMode) {
	PBUIPasteboardModeNoop,
	PBUIPasteboardModeCopy,
	PBUIPasteboardModePaste,
};

typedef NS_ENUM(NSUInteger, PBUIPasteboardType) {
	PBUIPasteboardTypeString,
	PBUIPasteboardTypeURL,
	PBUIPasteboardTypeImage,
	PBUIPasteboardTypeColor,
};

const char * PBUIPasteboardTypeGetStringFromType(PBUIPasteboardType type) {
	static NSArray const * types = nil;
	dispatch_once_t once;
	dispatch_once(&once, ^{
		types = @[
				(id)kUTTypeText,
				(id)kUTTypeURL,
				(id)kUTTypePNG,
				kUIKitTypeColor
			];
	});
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

PBUIPasteboardType PBUIPasteboardTypeOfFd(int fd) {
	@autoreleasepool {
		NSString * path = PBCreateFilePathFromFd(fd);
		NSString * UTI = PBCreateUTIStringFromFilePath(path);
		[path release];

		NSArray * typesArray = @[
			UIPasteboardTypeListString,
			UIPasteboardTypeListURL,
			UIPasteboardTypeListImage,
			UIPasteboardTypeListColor,
		];
		__block NSUInteger index = 0;
		[typesArray enumerateObjectsUsingBlock:^(NSArray * types, NSUInteger idx, BOOL * stop) {
			if ([types containsObject:UTI]) {
				index = idx;
				*stop = YES;
			}
		}];
		[UTI release];
		return (PBUIPasteboardType)index;
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
		buffer[i] = '\0';
		if ((newPtr = realloc(buffer, (i + 1) * sizeof(char))) != NULL) {
			buffer = (char *)newPtr;
		} else {
			free(buffer);
			i = 0;
			buffer = NULL;
		}
	}

	*length = i;
	return buffer;
}

char * PBUIPasteboardSaveImage(UIImage * image, char * path, size_t * lengthPtr) {
	if (!image) {
		return NULL;
	}

	NSString * ext = @(path).pathExtension;
	NSArray * supportedExtensions = @[
		@"png",
		@"jpg",
	];

	BOOL success = NO;
	NSURL *fileURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"com.uikit.pasteboard.buffer"]];
	NSError *error = nil;

	switch ([supportedExtensions indexOfObject:ext]) {
		case 0: {
			NSData * data = UIImagePNGRepresentation(image);
			if (![data writeToURL:fileURL options:NSDataWritingAtomic error:&error]) {
				fprintf(stderr, "Error <%s>.\n", error.description.UTF8String);
				break;
			}
			success = YES;
		} break;

		case 1: {
			fprintf(stderr,
				"JPG\n"
			);
		} break;
		default: {
			fprintf(stderr,
				"Extension '%s' not supported.\n"
				, ext.UTF8String
			);
		} break;
	}

	char * buffer = NULL;
	if (success) {
		size_t length = 0;
		int fd = open(fileURL.path.UTF8String, O_RDONLY);
		buffer = PBCreateBufferFromFd(fd, &length);
		close(fd);
		[NSFileManager.defaultManager removeItemAtURL:fileURL error:&error];
		if (length > 0) {
			*lengthPtr = length;
		}
	}
	return buffer;
}

void PBUIPasteboardPerformCopy(int fd) {
	PBUIPasteboardType inType = PBUIPasteboardTypeOfFd(fd);
	const char * inTypeString = PBUIPasteboardTypeGetStringFromType(inType);

	UIPasteboard * generalPb = UIPasteboard.generalPasteboard;

	switch (inType) {
		case PBUIPasteboardTypeString: {
			size_t length = 0;
			char * string = PBCreateBufferFromFd(fd, &length);
			if (length < 1) {
				break;
			}
			NSString * dataString = [NSString stringWithUTF8String:string];
			free(string);
			generalPb.string = dataString;
		} break;

		case PBUIPasteboardTypeImage: {
			char * path = filePathFromFd(fd);
			UIImage * image = [UIImage imageWithContentsOfFile:@(path)];
			generalPb.image = image;
			free(path);
		} break;

		default: {
			fprintf(stderr, "Resource type <%s> unsupported.\n", inTypeString);
		} break;
	}
}

void PBUIPasteboardPerformPaste(int fd) {
	PBUIPasteboardType outType = PBUIPasteboardTypeOfFd(fd);
	const char * outTypeString = PBUIPasteboardTypeGetStringFromType(outType);

	UIPasteboard * generalPb = UIPasteboard.generalPasteboard;

	switch (outType) {
		case PBUIPasteboardTypeString: {
			dprintf(fd, "%s", generalPb.string.UTF8String);
		} break;

		case PBUIPasteboardTypeImage: {
			char * path = filePathFromFd(fd);
			size_t length = 0;
			char * raw = PBUIPasteboardSaveImage(generalPb.image, path, &length);
			if (!raw) {
				fprintf(stderr, "No buffer.\n");
				break;
			}
			write(fd, raw, length);
			free(path);
		} break;

		default: {
			fprintf(stderr, "Resource type <%s> unsupported.\n", outTypeString);
		} break;
	}
}

int main(int argc, char **argv, char **envp) {
	@autoreleasepool {
		int inFD = STDIN_FILENO;
		int outFD = STDOUT_FILENO;

		PBUIPasteboardMode mode =
			isatty(inFD) ? PBUIPasteboardModePaste :
			isatty(outFD) ? PBUIPasteboardModeCopy :
			PBUIPasteboardModeCopy | PBUIPasteboardModePaste;

		if (mode & PBUIPasteboardModeCopy) {
			PBUIPasteboardPerformCopy(inFD);
		}

		if (mode & PBUIPasteboardModePaste) {
			PBUIPasteboardPerformPaste(outFD);
		}
	}
	return 0;
}

// vim:ft=objc
