#import "MDServer.h"
#import "MDLog.h"

#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <strings.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <unistd.h>

@interface MDServer () {
	int _listenFD;
	dispatch_queue_t _acceptQueue;
	dispatch_queue_t _connectionQueue;
	NSMutableDictionary<NSString *, NSString *> *_routes;
}

@property (nonatomic, readwrite) uint16_t port;
@property (nonatomic, readwrite, getter=isRunning) BOOL running;

@end

static NSString *MDMimeTypeForExtension(NSString *extension) {
	static NSDictionary<NSString *, NSString *> *types;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		types = @{
			@"mp3": @"audio/mpeg",
			@"m4a": @"audio/mp4",
			@"m4r": @"audio/mp4",
			@"m4b": @"audio/mp4",
			@"alac": @"audio/mp4",
			@"aac": @"audio/aac",
			@"wav": @"audio/wav",
			@"aif": @"audio/aiff",
			@"aiff": @"audio/aiff",
			@"caf": @"audio/x-caf",
			@"flac": @"audio/flac",
			@"mp4": @"video/mp4",
			@"m4v": @"video/mp4",
			@"mov": @"video/quicktime",
			@"jpg": @"image/jpeg",
			@"jpeg": @"image/jpeg",
			@"png": @"image/png",
		};
	});
	return types[extension.lowercaseString ?: @""] ?: @"application/octet-stream";
}

static NSString *MDHTTPDateString(void) {
	static NSDateFormatter *formatter;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		formatter = [NSDateFormatter new];
		formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
		formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"GMT"];
		formatter.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss 'GMT'";
	});
	@synchronized (formatter) {
		return [formatter stringFromDate:[NSDate date]];
	}
}

static const char *MDHeaderValue(const char *headers, const char *name) {
	size_t nameLength = strlen(name);
	const char *line = headers;
	while ((line = strstr(line, "\r\n")) != NULL) {
		line += 2;
		if (strncasecmp(line, name, nameLength) == 0 && line[nameLength] == ':') {
			line += nameLength + 1;
			while (*line == ' ' || *line == '\t') {
				line++;
			}
			return line;
		}
	}
	return NULL;
}

static BOOL MDSendAll(int fd, const void *bytes, size_t length) {
	const uint8_t *cursor = (const uint8_t *)bytes;
	while (length > 0) {
		ssize_t sent = send(fd, cursor, length, 0);
		if (sent < 0) {
			if (errno == EINTR) {
				continue;
			}
			return NO;
		}
		if (sent == 0) {
			return NO;
		}
		cursor += sent;
		length -= (size_t)sent;
	}
	return YES;
}

static void MDSendSimple(int fd, const char *status, const char *body) {
	size_t bodyLength = body ? strlen(body) : 0;
	char header[512];
	int headerLength = snprintf(header, sizeof(header),
		"HTTP/1.1 %s\r\n"
		"Content-Type: text/plain; charset=utf-8\r\n"
		"Content-Length: %zu\r\n"
		"Connection: close\r\n"
		"Cache-Control: no-store\r\n"
		"\r\n", status, bodyLength);
	MDSendAll(fd, header, (size_t)headerLength);
	if (bodyLength > 0) {
		MDSendAll(fd, body, bodyLength);
	}
}

@implementation MDServer

+ (instancetype)sharedServer {
	static MDServer *server;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		server = [[MDServer alloc] init];
	});
	return server;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_listenFD = -1;
		_routes = [NSMutableDictionary dictionary];
		_acceptQueue = dispatch_queue_create("com.musiccc.musicdrop.server.accept", DISPATCH_QUEUE_SERIAL);
		_connectionQueue = dispatch_queue_create("com.musiccc.musicdrop.server.connections", DISPATCH_QUEUE_CONCURRENT);
		[self start];
	}
	return self;
}

- (void)start {
	if (_listenFD >= 0) {
		return;
	}

	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		MDLog(@"Server: socket() failed: %s", strerror(errno));
		return;
	}

	int yes = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
	setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif

	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_family = AF_INET;
	address.sin_port = 0;
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);

	if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
		MDLog(@"Server: bind() failed: %s", strerror(errno));
		close(fd);
		return;
	}

	if (listen(fd, 16) != 0) {
		MDLog(@"Server: listen() failed: %s", strerror(errno));
		close(fd);
		return;
	}

	socklen_t length = sizeof(address);
	if (getsockname(fd, (struct sockaddr *)&address, &length) != 0) {
		MDLog(@"Server: getsockname() failed: %s", strerror(errno));
		close(fd);
		return;
	}

	_listenFD = fd;
	self.port = ntohs(address.sin_port);
	self.running = YES;
	MDLog(@"Server: listening on 127.0.0.1:%u", (unsigned)self.port);

	__weak MDServer *weakSelf = self;
	dispatch_async(_acceptQueue, ^{
		[weakSelf acceptLoop];
	});
}

- (void)acceptLoop {
	while (self->_listenFD >= 0) {
		int client = accept(self->_listenFD, NULL, NULL);
		if (client < 0) {
			if (errno == EINTR) {
				continue;
			}
			if (errno == EBADF || errno == EINVAL) {
				break;
			}
			usleep(10 * 1000);
			continue;
		}

		int yes = 1;
#ifdef SO_NOSIGPIPE
		setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
		struct timeval timeout;
		timeout.tv_sec = 15;
		timeout.tv_usec = 0;
		setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
		timeout.tv_sec = 60;
		setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

		__weak MDServer *weakSelf = self;
		dispatch_async(_connectionQueue, ^{
			[weakSelf handleClient:client];
		});
	}
}

- (nullable NSString *)pathForToken:(NSString *)token {
	@synchronized (self->_routes) {
		return self->_routes[token];
	}
}

- (void)handleClient:(int)fd {
	char request[16385];
	ssize_t total = 0;

	while (total < (ssize_t)sizeof(request) - 1) {
		ssize_t received = recv(fd, request + total, sizeof(request) - 1 - (size_t)total, 0);
		if (received <= 0) {
			break;
		}
		total += received;
		request[total] = '\0';
		if (strstr(request, "\r\n\r\n")) {
			break;
		}
	}

	if (total <= 0) {
		close(fd);
		return;
	}

	char method[16] = {0};
	char target[2048] = {0};
	char version[16] = {0};
	if (sscanf(request, "%15s %2047s %15s", method, target, version) != 3) {
		MDSendSimple(fd, "400 Bad Request", "Bad request\n");
		close(fd);
		return;
	}

	char *query = strchr(target, '?');
	if (query) {
		*query = '\0';
	}

	BOOL isHead = strcmp(method, "HEAD") == 0;
	if (!isHead && strcmp(method, "GET") != 0) {
		MDSendSimple(fd, "405 Method Not Allowed", "Method not allowed\n");
		close(fd);
		return;
	}

	if (strcmp(target, "/") == 0) {
		const char *body = "MusicDrop server is running.\n";
		size_t bodyLength = strlen(body);
		char header[512];
		int headerLength = snprintf(header, sizeof(header),
			"HTTP/1.1 200 OK\r\n"
			"Content-Type: text/plain; charset=utf-8\r\n"
			"Content-Length: %zu\r\n"
			"Connection: close\r\n"
			"\r\n", bodyLength);
		MDSendAll(fd, header, (size_t)headerLength);
		if (!isHead) {
			MDSendAll(fd, body, bodyLength);
		}
		close(fd);
		return;
	}

	if (strncmp(target, "/media/", 7) != 0) {
		MDSendSimple(fd, "404 Not Found", "Not found\n");
		close(fd);
		return;
	}

	NSString *route = [NSString stringWithUTF8String:target + 7];
	NSString *token = [[route componentsSeparatedByString:@"."] firstObject];
	NSString *path = token.length > 0 ? [self pathForToken:token] : nil;
	if (!path) {
		MDSendSimple(fd, "404 Not Found", "Not found\n");
		close(fd);
		return;
	}

	struct stat info;
	const char *filePath = path.fileSystemRepresentation;
	if (stat(filePath, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0) {
		MDSendSimple(fd, "404 Not Found", "Not found\n");
		close(fd);
		return;
	}

	long long fileSize = (long long)info.st_size;
	long long start = 0;
	long long end = fileSize - 1;
	BOOL hasRange = NO;

	const char *rangeHeader = MDHeaderValue(request, "Range");
	if (rangeHeader) {
		char range[128] = {0};
		if (sscanf(rangeHeader, "%127[^\r\n]", range) == 1 && strncmp(range, "bytes=", 6) == 0) {
			const char *spec = range + 6;
			if (spec[0] == '-') {
				long long suffix = atoll(spec + 1);
				if (suffix > 0) {
					start = fileSize - suffix;
					if (start < 0) {
						start = 0;
					}
					hasRange = YES;
				}
			} else {
				start = atoll(spec);
				const char *dash = strchr(spec, '-');
				if (dash && dash[1] != '\0') {
					end = atoll(dash + 1);
				}
				if (end >= fileSize) {
					end = fileSize - 1;
				}
				hasRange = YES;
			}
		}
	}

	if (hasRange && (start < 0 || start >= fileSize || end < start)) {
		char header[256];
		int headerLength = snprintf(header, sizeof(header),
			"HTTP/1.1 416 Range Not Satisfiable\r\n"
			"Content-Range: bytes */%lld\r\n"
			"Content-Length: 0\r\n"
			"Connection: close\r\n"
			"\r\n", fileSize);
		MDSendAll(fd, header, (size_t)headerLength);
		close(fd);
		return;
	}

	long long contentLength = end - start + 1;
	NSString *extension = path.pathExtension;
	NSString *mime = MDMimeTypeForExtension(extension);

	char rangeLine[128] = {0};
	if (hasRange) {
		snprintf(rangeLine, sizeof(rangeLine), "Content-Range: bytes %lld-%lld/%lld\r\n",
				 start, end, fileSize);
	}

	int file = open(filePath, O_RDONLY);
	if (file < 0) {
		MDSendSimple(fd, "500 Internal Server Error", "Could not open file\n");
		close(fd);
		return;
	}

	NSString *dateString = MDHTTPDateString();
	char header[1024];
	int headerLength = snprintf(header, sizeof(header),
		"HTTP/1.1 %s\r\n"
		"Date: %s\r\n"
		"Content-Type: %s\r\n"
		"Content-Length: %lld\r\n"
		"Accept-Ranges: bytes\r\n"
		"%s"
		"Connection: close\r\n"
		"Cache-Control: no-store\r\n"
		"\r\n",
		hasRange ? "206 Partial Content" : "200 OK",
		dateString.UTF8String,
		mime.UTF8String,
		contentLength,
		rangeLine);

	if (!MDSendAll(fd, header, (size_t)headerLength) || isHead) {
		close(file);
		close(fd);
		return;
	}

	char buffer[65536];
	long long remaining = contentLength;
	off_t offset = (off_t)start;
	BOOL ok = YES;
	while (remaining > 0) {
		size_t wanted = (size_t)((remaining < (long long)sizeof(buffer)) ? remaining : (long long)sizeof(buffer));
		ssize_t readCount = pread(file, buffer, wanted, offset);
		if (readCount <= 0) {
			ok = NO;
			break;
		}
		if (!MDSendAll(fd, buffer, (size_t)readCount)) {
			ok = NO;
			break;
		}
		remaining -= readCount;
		offset += readCount;
	}
	close(file);

	if (ok) {
		MDLog(@"Server: %s %s -> %lld bytes", method, target, contentLength);
	} else {
		MDLog(@"Server: %s %s ended early (%lld bytes left)", method, target, remaining);
	}
	close(fd);
}

- (NSURL *)registerFilePath:(NSString *)path extension:(NSString *)extension {
	if (path.length == 0) {
		return nil;
	}
	if (!self.isRunning) {
		[self start];
	}
	if (!self.isRunning) {
		return nil;
	}

	NSString *ext = extension.lowercaseString;
	if (ext.length == 0) {
		ext = path.pathExtension.lowercaseString;
	}
	NSCharacterSet *allowed = [NSCharacterSet alphanumericCharacterSet];
	if (ext.length == 0 || [ext rangeOfCharacterFromSet:allowed.invertedSet].location != NSNotFound) {
		ext = @"bin";
	}

	NSString *token = [[NSUUID UUID].UUIDString lowercaseString];
	token = [token stringByReplacingOccurrencesOfString:@"-" withString:@""];

	@synchronized (self->_routes) {
		self->_routes[token] = path;
	}

	return [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/media/%@.%@",
								 self.port, token, ext]];
}

- (void)unregisterToken:(NSString *)token {
	if (token.length == 0) {
		return;
	}
	@synchronized (self->_routes) {
		[self->_routes removeObjectForKey:token];
	}
}

@end
