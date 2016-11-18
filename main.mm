#import <UIKit/UIPasteboard.h>
#import <MobileCoreServices/UTType.h>

#include <dlfcn.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syslimits.h>
#include <fcntl.h>

#include <objc/runtime.h>
#include <objc/message.h>

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
	static const char *types[] = {
		"public.text",
		"public.url",
		"public.png",
		"com.apple.uikit.color"
	};
	return types[type];
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
			UIPasteboardTypeListString?:@[@"public.utf8-plain-text",@"public.text"],
			UIPasteboardTypeListURL?:@[@"public.url"],
			UIPasteboardTypeListImage?:@[@"public.png",@"public.jpeg",@"com.compuserve.gif",@"com.apple.uikit.image"],
			UIPasteboardTypeListColor?:@[@"com.apple.uikit.color"],
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

char * PBCreateBufferFromStdin(size_t * length) {
	char c;
	size_t p4kB = 4096, i = 0;
	void * newPtr = NULL;
	char * buffer = (char *)malloc(p4kB * sizeof(char));

	while (buffer != NULL && (scanf("%c", &c) != EOF)) {
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

void PBUIPasteboardPerformCopy(int fd) {
	PBUIPasteboardType inType = PBUIPasteboardTypeOfFd(fd);
	const char * inTypeString = PBUIPasteboardTypeGetStringFromType(inType);

	UIPasteboard * generalPb = UIPasteboard.generalPasteboard;

	switch (inType) {
		case PBUIPasteboardTypeString: {
			size_t length = 0;
			char * string = PBCreateBufferFromStdin(&length);
			if (length < 1) {
				break;
			}
			NSString * dataString = [NSString stringWithUTF8String:string];
			free(string);
#if 01
			NSData * data = [dataString dataUsingEncoding:NSUTF8StringEncoding];
			[generalPb setData:data forPasteboardType:@(inTypeString)];
#else
			generalPb.string = dataString;
#endif
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
	NSData * outValue = [generalPb dataForPasteboardType:@(outTypeString)];

	switch (outType) {
		case PBUIPasteboardTypeString: {
#if 01
			NSString * dataString = [[NSString alloc] initWithData:outValue encoding:NSUTF8StringEncoding];
			fprintf(stdout, "%s", dataString.UTF8String);
			[dataString release];
#else
			fprintf(fd, "%s", generalPb.string.UTF8String);
#endif
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
