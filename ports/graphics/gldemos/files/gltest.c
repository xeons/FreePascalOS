/*
 * FreePascalOS
 * Copyright (C) 2026 Brandon Scott
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

/*
 * gltest: Mesa without a window system. On EGL's surfaceless platform
 * it makes an OpenGL ES 2 context on a pbuffer, clears it, draws a
 * triangle with a shader, reads the pixels back and checks them; then
 * the same with an OpenGL ES 1.1 context and a desktop OpenGL context
 * (its functions from eglGetProcAddress). Prints each check and ends
 * with "gltest: all N checks passed" (status 0) or the number failed.
 */
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SURFACE_SIDE 64

static int checks_run;
static int checks_failed;

static void check(int condition, const char *what)
{
	checks_run++;
	if (!condition)
		checks_failed++;
	printf("gltest: %s %s\n", condition ? "ok  " : "FAIL", what);
}

static int near(int value, int expected)
{
	return abs(value - expected) <= 2;
}

/* Whether the pixel at (x, y) of what is bound reads as r, g, b. */
static int pixel_is(int x, int y, int r, int g, int b)
{
	unsigned char rgba[4] = {0, 0, 0, 0};
	glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
	if (!(near(rgba[0], r) && near(rgba[1], g) && near(rgba[2], b)))
		printf("gltest:      pixel %d,%d is %d %d %d, expected %d %d %d\n",
		       x, y, rgba[0], rgba[1], rgba[2], r, g, b);
	return near(rgba[0], r) && near(rgba[1], g) && near(rgba[2], b);
}

static EGLDisplay open_display(void)
{
	PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
		(PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
	const char *client_extensions = eglQueryString(EGL_NO_DISPLAY, EGL_EXTENSIONS);
	check(client_extensions != NULL && strstr(client_extensions, "EGL_MESA_platform_surfaceless") != NULL,
	      "EGL offers the surfaceless platform");
	if (get_platform_display == NULL)
		return EGL_NO_DISPLAY;
	return get_platform_display(EGL_PLATFORM_SURFACELESS_MESA, EGL_DEFAULT_DISPLAY, NULL);
}

static EGLConfig choose_config(EGLDisplay display, EGLint renderable)
{
	const EGLint attributes[] = {
		EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
		EGL_RENDERABLE_TYPE, renderable,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
		EGL_NONE,
	};
	EGLConfig config = NULL;
	EGLint count = 0;
	if (!eglChooseConfig(display, attributes, &config, 1, &count) || count == 0)
		return NULL;
	return config;
}

static EGLSurface make_pbuffer(EGLDisplay display, EGLConfig config)
{
	const EGLint attributes[] = {EGL_WIDTH, SURFACE_SIDE, EGL_HEIGHT, SURFACE_SIDE, EGL_NONE};
	return eglCreatePbufferSurface(display, config, attributes);
}

static GLuint compile_shader(GLenum kind, const char *source)
{
	GLuint shader = glCreateShader(kind);
	GLint compiled = 0;
	glShaderSource(shader, 1, &source, NULL);
	glCompileShader(shader);
	glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
	if (!compiled) {
		char log[512];
		glGetShaderInfoLog(shader, sizeof(log), NULL, log);
		printf("gltest:      shader: %s\n", log);
	}
	return shader;
}

static void test_gles2(EGLDisplay display)
{
	static const char *vertex_source =
		"attribute vec2 position;\n"
		"void main() { gl_Position = vec4(position, 0.0, 1.0); }\n";
	static const char *fragment_source =
		"precision mediump float;\n"
		"uniform vec4 color;\n"
		"void main() { gl_FragColor = color; }\n";
	static const GLfloat triangle[] = {-0.5f, -0.5f, 0.5f, -0.5f, 0.0f, 0.5f};
	const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
	EGLConfig config;
	EGLSurface surface;
	EGLContext context;
	GLuint program;
	GLint linked = 0;

	eglBindAPI(EGL_OPENGL_ES_API);
	config = choose_config(display, EGL_OPENGL_ES2_BIT);
	check(config != NULL, "a pbuffer configuration for OpenGL ES 2");
	if (config == NULL)
		return;
	surface = make_pbuffer(display, config);
	context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
	check(surface != EGL_NO_SURFACE && context != EGL_NO_CONTEXT, "an OpenGL ES 2 context and pbuffer");
	check(eglMakeCurrent(display, surface, surface, context), "made current");

	printf("gltest:      GL_VENDOR %s\n", (const char *)glGetString(GL_VENDOR));
	printf("gltest:      GL_RENDERER %s\n", (const char *)glGetString(GL_RENDERER));
	printf("gltest:      GL_VERSION %s\n", (const char *)glGetString(GL_VERSION));
	printf("gltest:      GL_SHADING_LANGUAGE_VERSION %s\n",
	       (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION));
	check(glGetString(GL_RENDERER) != NULL, "OpenGL ES 2 names its renderer");

	glViewport(0, 0, SURFACE_SIDE, SURFACE_SIDE);
	glClearColor(0.0f, 0.0f, 1.0f, 1.0f);
	glClear(GL_COLOR_BUFFER_BIT);
	check(pixel_is(1, 1, 0, 0, 255), "cleared to blue");

	program = glCreateProgram();
	glAttachShader(program, compile_shader(GL_VERTEX_SHADER, vertex_source));
	glAttachShader(program, compile_shader(GL_FRAGMENT_SHADER, fragment_source));
	glBindAttribLocation(program, 0, "position");
	glLinkProgram(program);
	glGetProgramiv(program, GL_LINK_STATUS, &linked);
	check(linked, "a GLSL ES program compiled and linked");
	glUseProgram(program);
	glUniform4f(glGetUniformLocation(program, "color"), 1.0f, 0.5f, 0.0f, 1.0f);
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, triangle);
	glEnableVertexAttribArray(0);
	glDrawArrays(GL_TRIANGLES, 0, 3);
	glFinish();
	check(pixel_is(SURFACE_SIDE / 2, SURFACE_SIDE / 2, 255, 128, 0), "the triangle's middle is orange");
	check(pixel_is(1, SURFACE_SIDE - 2, 0, 0, 255), "outside it still blue");
	check(glGetError() == GL_NO_ERROR, "no GL error");

	eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(display, context);
	eglDestroySurface(display, surface);
}

/* OpenGL ES 1.1 through its own library's entry points, looked up. */
static void test_gles1(EGLDisplay display)
{
	typedef void (*clear_color_function)(GLfloat, GLfloat, GLfloat, GLfloat);
	typedef void (*clear_function)(GLbitfield);
	const EGLint context_attributes[] = {EGL_CONTEXT_CLIENT_VERSION, 1, EGL_NONE};
	EGLConfig config;
	EGLSurface surface;
	EGLContext context;
	clear_color_function clear_color;
	clear_function clear;

	eglBindAPI(EGL_OPENGL_ES_API);
	config = choose_config(display, EGL_OPENGL_ES_BIT);
	check(config != NULL, "a pbuffer configuration for OpenGL ES 1");
	if (config == NULL)
		return;
	surface = make_pbuffer(display, config);
	context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
	check(context != EGL_NO_CONTEXT && eglMakeCurrent(display, surface, surface, context),
	      "an OpenGL ES 1 context made current");
	clear_color = (clear_color_function)eglGetProcAddress("glClearColor");
	clear = (clear_function)eglGetProcAddress("glClear");
	if (clear_color != NULL && clear != NULL) {
		clear_color(0.0f, 1.0f, 0.0f, 1.0f);
		clear(GL_COLOR_BUFFER_BIT);
	}
	check(pixel_is(3, 3, 0, 255, 0), "OpenGL ES 1 cleared to green");
	eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(display, context);
	eglDestroySurface(display, surface);
}

/* Desktop OpenGL: a compatibility context, functions by name. */
static void test_desktop_gl(EGLDisplay display)
{
	typedef const GLubyte *(*get_string_function)(GLenum);
	typedef void (*clear_color_function)(GLfloat, GLfloat, GLfloat, GLfloat);
	typedef void (*clear_function)(GLbitfield);
	EGLConfig config;
	EGLSurface surface;
	EGLContext context;
	get_string_function get_string;
	clear_color_function clear_color;
	clear_function clear;

	check(eglBindAPI(EGL_OPENGL_API), "EGL takes the desktop OpenGL API");
	config = choose_config(display, EGL_OPENGL_BIT);
	check(config != NULL, "a pbuffer configuration for desktop OpenGL");
	if (config == NULL)
		return;
	surface = make_pbuffer(display, config);
	context = eglCreateContext(display, config, EGL_NO_CONTEXT, NULL);
	check(context != EGL_NO_CONTEXT && eglMakeCurrent(display, surface, surface, context),
	      "a desktop OpenGL context made current");
	get_string = (get_string_function)eglGetProcAddress("glGetString");
	clear_color = (clear_color_function)eglGetProcAddress("glClearColor");
	clear = (clear_function)eglGetProcAddress("glClear");
	check(get_string != NULL && clear_color != NULL && clear != NULL, "desktop OpenGL functions found");
	if (get_string == NULL || clear_color == NULL || clear == NULL)
		return;
	printf("gltest:      desktop GL_VERSION %s\n", (const char *)get_string(GL_VERSION));
	clear_color(1.0f, 0.0f, 0.0f, 1.0f);
	clear(GL_COLOR_BUFFER_BIT);
	check(pixel_is(5, 5, 255, 0, 0), "desktop OpenGL cleared to red");
	eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
	eglDestroyContext(display, context);
	eglDestroySurface(display, surface);
}

int main(void)
{
	EGLint major = 0, minor = 0;
	EGLDisplay display = open_display();

	check(display != EGL_NO_DISPLAY, "a surfaceless EGL display");
	if (display == EGL_NO_DISPLAY)
		return 1;
	check(eglInitialize(display, &major, &minor), "EGL initialized");
	printf("gltest:      EGL %d.%d, %s, %s\n", major, minor, eglQueryString(display, EGL_VENDOR),
	       eglQueryString(display, EGL_CLIENT_APIS));

	test_gles2(display);
	test_gles1(display);
	test_desktop_gl(display);

	eglTerminate(display);
	if (checks_failed == 0) {
		printf("gltest: all %d checks passed\n", checks_run);
		return 0;
	}
	printf("gltest: %d of %d checks failed\n", checks_failed, checks_run);
	return 1;
}
