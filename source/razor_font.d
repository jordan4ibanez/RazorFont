/**
The Sharpest Font Library For D Game Development
*/
module razor_font;

import std.conv;
import std.file;
import std.json;
import std.typecons;
import color;
import png;
import std.math;

//  ____________________________
// |         RAZOR FONT         |
// |____________________________|
//  \            /\            /
//  /            \/            \
// | The Sharpest Font Library  |
// |   For D Game Development   |
// |____________________________|

/**
Stores IMPORTANT font data to be reused by Razor Font - These are stored in static memory in the program
Counts are so we can grab a slice of this information because anything after it WILL be garbage data
*/
/// The current character limit (letters in string)
private immutable int CHARACTER_LIMIT = 4096;
/// 4 vec2 (so 8 per char) vertex positions
private double[4 * 2 * CHARACTER_LIMIT] vertexCache;
// 4 vec4 (so 16 per char) colors - defaults to 0,0,0,1 rgba
private double[4 * 4 * CHARACTER_LIMIT] colorCache;

/// 4 vec2 (so 8 per char) texture coordinate positions
private double[8 * CHARACTER_LIMIT] textureCoordinateCache;
/// 2 tris (so 6 per char) indices
private int[6 * CHARACTER_LIMIT] indicesCache;
/// The count of each of these so we can grab a slice of data fresh out of the oven, delicious!
private int vertexCount            = 0;
private int textureCoordinateCount = 0;
private int indicesCount           = 0;
private int colorCount             = 0;
private int chars                  = 0;

/**
This allows batch rendering to a "canvas" ala vertex positionining
With this you can shovel one giant lump of data into a vao or whatever you're using.
This is optional though, you can do whatever you want!
*/
private double canvasWidth  = -1;
private double canvasHeight = -1;

/**
These store constant data that is highly repetitive
*/
private immutable double[8] RAW_VERTEX  = [ 0,0, 0,1, 1,1, 1,0 ];
private immutable int[6]    RAW_INDICES = [ 0,1,2, 2,3,0 ];

/**
The offset of the text shadowing.

Note: Since offset is only proportional to the font size when rendering,
the offset is completely detached from the font spec!

The font spec has no bearing on how the offset is calculated. Only font size.

0.05 by default because I think it looks nice. :)
*/
private double shadowOffsetX = 0.05;
private double shadowOffsetY = 0.05;

/**
The RGBA components of the shadow
*/
private double[4] shadowColor = [0,0,0,1];

/**
Are shadows enabled?

They get disabled everytime you run renderToCanvas().
This is so there basically isn't a "shadow memory leak".

As in: Oops I forgot to disable shadows now everything after has a 
shadow for some reason!
*/
private bool shadowsEnabled = false;

/**
Allows turning off the shadowing color fill for performance.
Say you want a rainbow shadow, you can use this for that.
*/
private bool shadowColoringEnabled = true;

/**
This is a very simple fix for static memory arrays being filled with no.
A simple on switch for initialization.
To use RazorFont, you must create a font, so it runs this in there.
*/
private bool initializedColorArray = false;
private void initColorArray() {
    if (initializedColorArray) {
        return;
    }
    initializedColorArray = true;
    for (int i = 0; i < 16 * CHARACTER_LIMIT; i += 4) {
        colorCache[i]     = 0;
        colorCache[i + 1] = 0;
        colorCache[i + 2] = 0;
        colorCache[i + 3] = 1;
    }
}

/**
Caches the current font in use.
Think of this like the golfball on an IBM Selectric.
You can use one ball, type out in one font. Then flush to your render target.
Then you can swap to another ball and type in another font.

Just remember, you must flush or this is going to throw an error because
it would create garbage text data without a lock when swapping golfballs, aka fonts.
*/
private RazorFont currentFont = null;

/// This stores the current font name as a string
private string currentFontName;

/// This is the lock described in the comment above;
private bool fontLock = false;

/// Stores all fonts
private RazorFont[string] razorFonts;

/// A simple struct to get the font data for the shader
struct RazorFontData {
    double[] vertexPositions;
    double[] textureCoordinates;
    int[]    indices;
    double[] colors;
}
/// A simple struct to get the width and height of rendered text
struct RazorTextSize {
    double width  = 0.0;
    double height = 0.0;
}

// Allows an automatic upload into whatever render target (OpenGL, Vulkan, Metal, DX) as a string file location
private void delegate(string) renderTargetAPICallString = null;

// Allows DIRECT automatic upload into whatever render target (OpenGL, Vulkan, Metal, DX) as RAW data
private void delegate(ubyte[], int, int) renderTargetAPICallRAW = null;

// Allows an automate render into whatever render target (OpenGL, Vulkan, Metal, DX) simply by calling render()
private void delegate(RazorFontData) renderApiRenderCall = null;


/**
Allows automatic render target (OpenGL, Vulkan, Metal, DX) passthrough instantiation.
This can basically pass a file location off to your rendering engine and auto load it into memory.
*/
void setRenderTargetAPICallString(void delegate(string) apiStringFunction) {
    if (renderTargetAPICallRAW !is null) {
        throw new Exception("Razor Font: You already set the RAW api integration function!");
    }
    renderTargetAPICallString = apiStringFunction;
}


/**
Allows automatic render target (OpenGL, Vulkan, Metal, DX) DIRECT instantiation.
This allows the render engine to AUTOMATICALLY upload the image as RAW data.
ubyte[] = raw data. int = width. int = height.
*/
void setRenderTargetAPICallRAW(void delegate(ubyte[], int, int) apiRAWFunction) {
    if (renderTargetAPICallString !is null) {
        throw new Exception("Razor Font: You already set the STRING api integration function!");
    }
    renderTargetAPICallRAW = apiRAWFunction;
}

/**
Allows automatic render target (OpenGL, Vulkan, Metal, DX) DIRECT rendering via RazorFont.
You can simply call render() on the library and it will automatically do whatever you
tell it to with this delegate function. This will also automatically run flush().
*/
void setRenderFunc(void delegate(RazorFontData) renderApiRenderFunction) {
    if (renderApiRenderCall !is null) {
        throw new Exception("Razor Font: You already set the RENDER api integration function!");
    }
    renderApiRenderCall = renderApiRenderFunction;
}


// A simple font container
private class RazorFont {

    // Font base pallet width (in pixels)
    int palletWidth  = 0;
    int palletHeight = 0;

    // Pixel space (literally) between characters in pallet
    int border = 0;

    // Number of characters (horizontal, aka X)
    int rows = 0;

    // How far the letters are from each other
    double spacing = 1.0;

    // How big the space character is (' ')
    double spaceCharacterSize = 4.0;

    // Character pallet (individual) in pixels
    int characterWidth   = 0;
    int charactertHeight = 0;
    
    // Readonly specifier if kerning was enabled
    bool kerned = false;

    // Readonly specifier if trimming was enabled
    bool trimmedX = false;
    bool trimmedY = false;

    // Readonly directory for texture (entire, including the .png)
    string fileLocation;

    // Character map - stored as a linear associative array for O(1) retrieval
    /**
    Stores as:
    [
        -x -y,
        -x +y, 
        +x +y,
        +x -y
    ]
    or this, if it's easier to understand:
    [
        top    left,
        bottom left,
        bottom right,
        top    right
    ]
    GPU optimized vertex positions!

    Accessed as:
    double[] myCoolBlah = map["whatever letter/unicode thing you're getting"];

    The last 1 values specify width of the character
    */
    double[9][dchar] map;

    // Stores the map raw as a linear array before processed
    string rawMap;
}

/**
Create a font from your PNG JSON pairing in the directory.

You do not specify an extension.

So if you have: cool.png and cool.json
You would call this as: createFont("fonts/cool")

Name is an optional. You will call into Razor Font by this name.

If you do not specify a name, you must call into Razor Font by the fileLocation, literal.

If you turn on trimming, your font will go from monospace to proportional.

Spacing is how far the letters are from each other. Default: 1.0 pixel

spaceCharacterSize is how big the ' ' (space) character is. By default, it's 4 pixels wide.
*/
void createFont(string fileLocation, string name = "", bool trimming = false, double spacing = 1.0, double spaceCharacterSize = 4.0) {

    // This is the fix explained above
    initColorArray();

    //! Place holder for future
    bool kerning = false;

    // Are we using the fileLocation as the key, or did they specify a name?
    const string key = name == "" ? fileLocation : name;

    const string pngLocation = fileLocation ~ ".png";
    const string jsonLocation = fileLocation ~ ".json";

    // Make sure the files exist
    checkFilesExist(pngLocation, jsonLocation);

    // Automate existing engine integration
    tryCallingRAWApi(pngLocation);
    tryCallingStringApi(pngLocation);

    // Create the Font object
    RazorFont fontObject = new RazorFont();

    // Store the file location in the object
    fontObject.fileLocation = pngLocation;

    // Now parse the json, and pass it into object
    parseJson(fontObject, jsonLocation);

    // Now encode the linear string as a keymap of raw graphics positions
    encodeGraphics(fontObject, kerning, trimming, spacing, spaceCharacterSize);

    // Finally add it into the library
    razorFonts[key] = fontObject;

}

//* ============================ BEGIN GRAPHICS DISPATCH ===========================

/**
Allows you to blanket set the color for the entire canvas.

Be careful though, this overwrites the entire color cache
after the currently rendered character position in memory!
*/
void switchColors(double r, double g, double b, double a = 1.0) {
    for (int i = colorCount; i < colorCache.length; i += 4) {
        colorCache[i]     = r;
        colorCache[i + 1] = g;
        colorCache[i + 2] = b;
        colorCache[i + 3] = a;
    }
}

/**
Allows you to set the offet of the text shadowing.

This is RELATIVE via the font size so it will remain consistent
across any font size!

Remember: Offset will become reset to default when you call renderToCanvas()
*/
void setShadowOffset(double x, double y) {
    shadowOffsetX = x / 10.0;
    shadowOffsetY = y / 10.0;
}

/**
Allows you to blanket set the shadow color for the entire canvas after the current character.

Remember: When you renderToCanvas() shadow colors will default back to black.
*/
void switchShadowColor(double r, double g, double b, double a = 1.0) {
    shadowColor[0] = r;
    shadowColor[1] = g;
    shadowColor[2] = b;
    shadowColor[3] = a;
}


/**
Allows you to blanket a range of characters in the canvas with a color.

So if you have: abcdefg
And run setColorRange(0.5,0.5,0.5, 1, 3, 5)
Now e and f are gray. Alpha 1.0
*/
void setColorRange(int start, int end, double r, double g, double b, double a) {
    for (int i = start * 16; i < end * 16; i += 4) {
        colorCache[i]     = r;
        colorCache[i + 1] = g;
        colorCache[i + 2] = b;
        colorCache[i + 3] = a;
    }
}

/**
Allows you to set individual character colors
*/
void setColorChar(int charIndex, double r, double g, double b, double a = 1.0) {
    const int startIndex = charIndex * 16;
    for (int i = startIndex; i < startIndex + 16; i += 4) {
        colorCache[i]     = r;
        colorCache[i + 1] = g;
        colorCache[i + 2] = b;
        colorCache[i + 3] = a;
    }
}

/**
Allows you to directly work on vertex position colors in a character.
Using direct points (verbose)
*/
void setColorPoints(
    int charIndex,

    double topLeftR,
    double topLeftG,
    double topLeftB,
    double topLeftA,

    double bottomLeftR,
    double bottomLeftG,
    double bottomLeftB,
    double bottomLeftA,

    double bottomRightR,
    double bottomRightG,
    double bottomRightB,
    double bottomRightA,

    double topRightR,
    double topRightG,
    double topRightB,
    double topRightA
) {
    const int startIndex = charIndex * 16;
    
    // It's already immensely verbose, let's just add on to this verbosity
    
    colorCache[startIndex]      = topLeftR;
    colorCache[startIndex + 1]  = topLeftG;
    colorCache[startIndex + 2]  = topLeftB;
    colorCache[startIndex + 3]  = topLeftA;

    colorCache[startIndex + 4]  = bottomLeftR;
    colorCache[startIndex + 5]  = bottomLeftG;
    colorCache[startIndex + 6]  = bottomLeftB;
    colorCache[startIndex + 7]  = bottomLeftA;

    colorCache[startIndex + 8]  = bottomRightR;
    colorCache[startIndex + 9]  = bottomRightG;
    colorCache[startIndex + 10] = bottomRightB;
    colorCache[startIndex + 11] = bottomRightA;

    colorCache[startIndex + 12] = topRightR;
    colorCache[startIndex + 13] = topRightG;
    colorCache[startIndex + 14] = topRightB;
    colorCache[startIndex + 15] = topRightA;
}

/**
Allows you to directly work on vertex position colors in a character.
Using direct points (tidy).
double vec is [R,G,B,A]
*/
void setColorPoints(int charIndex, double[4] topLeft, double[4] bottomLeft, double[4] bottomRight, double[4] topRight) {
    const int startIndex = charIndex * 16;  
    foreach(externalIndex, vec4; [topLeft, bottomLeft, bottomRight, topRight]) {
        foreach (index, value; vec4) {
            colorCache[startIndex + (externalIndex * 4) + index] = value;
        }
    }
}

/// Allows you to get the max amount of characters allowed in canvas
int getMaxChars() {
    return CHARACTER_LIMIT;
}

/**
Allows you to index the current amount of characters on the canvas. This does
not include spaces and carriage returns. You MUST call renderToCanvas before
calling this otherwise this will always be 0 when you call it.
*/
int getCurrentCharacterIndex() {
    return chars;
}

/**
Allows you to extract the current font PNG file location automatically
*/
string getCurrentFontTextureFileLocation() {
    if (currentFont is null) {
        throw new Exception("Razor Font: Can't get a font file location! You didn't select one!");
    }
    return currentFont.fileLocation;
}

/**
Turns on shadowing.

Rememeber: This creates twice as many characters because
you have to render a background, then a foreground.

You can also do some crazy stuff with shadows because the shadow
colors are stored in the same color cache as regular text.

Remember: When you renderToCanvas() shadows turn off.
*/
void enableShadows() {
    shadowsEnabled = true;
}


/// Allows you to render to a canvas using top left as a base position
void setCanvasSize(double width, double height) {
    // Dividing by 2.0 because my test environment shader renders to center on pos(0,0) top left
    canvasWidth = width / 2.0;
    canvasHeight = height / 2.0;
}

/**
Automatically flushes out the cache, handing the data structure off to
the delegate function you defined via setRenderFunc()
*/
void render() {
    if (renderApiRenderCall is null) {
        throw new Exception("Razor Font: You did not set a render api call!");
    }

    renderApiRenderCall(flush());
}


/// Flushes out the cache, gives you back a font struct containing the raw data
RazorFontData flush() {

    fontLock = false;
    
    RazorFontData returningStruct = RazorFontData(
        vertexCache[0..vertexCount],
        textureCoordinateCache[0..textureCoordinateCount],
        indicesCache[0..indicesCount],
        colorCache[0..colorCount]
    );

    // Reset the counters
    vertexCount = 0;
    textureCoordinateCount = 0;
    indicesCount = 0;
    colorCount = 0;
    chars = 0;

    return returningStruct;
}

/// Allows you to get text size to do interesting things. Returns as RazorTextSize struct
RazorTextSize getTextSize(double fontSize, string text) {
    double accumulatorX = 0.0;
    double accumulatorY = 0.0;
    // Cache spacing
    const double spacing = currentFont.spacing * fontSize;
    // Cache space (' ') character
    const double spaceCharacterSize = currentFont.spaceCharacterSize * fontSize;

    // Can't get the size if there's no font!
    if (currentFont is null) {
        throw new Exception("Razor Font: Tried to get text size without selecting a font! " ~
            "You must select a font before getting the size of text with it!");
    }
    
    foreach (key, character; text) {

        // Skip space
        if (character == ' ') {
            accumulatorX += spaceCharacterSize;
            continue;
        }
        // Move down 1 space Y
        if (character == '\n') {
            accumulatorY += fontSize;
            continue;
        }
        
        // Skip unknown character
        if (character !in currentFont.map) {
            continue;
        }

        // Font stores character width in index 9 (8 [0 count])
        accumulatorX += (currentFont.map[character][8] * fontSize) + spacing;
    }

    // Add a last bit of the height offset
    accumulatorY += fontSize;
    // Remove the last bit of spacing
    accumulatorX -= spacing;

    // Finally, if shadowing is enabled, add in shadowing offset
    if (shadowsEnabled) {
        accumulatorX += (shadowOffsetX * fontSize);
        accumulatorY += (shadowOffsetY * fontSize);
    }

    return RazorTextSize(accumulatorX, accumulatorY);
}

/**
Selects and caches the font of your choosing.

Remember: You must flush the cache before choosing a new font.

This is done because all fonts are different. It would create garbage
data on screen without this.
*/
void selectFont(string font) {

    if (fontLock) {
        throw new Exception("You must flush() out the cache before selecting a new font!");
    }

    // Can't render if that font doesn't exist
    if (font !in razorFonts) {
        throw new Exception(font ~ " is not a registered font!");
    }

    // Now store and lock
    currentFont = razorFonts[font];
    currentFontName = font;
    fontLock = true;
}

/**
Render to the canvas. Remember: You must run flush() to collect this canvas.
If rounding is enabled, it will attempt to keep your text aligned with the pixels on screen
to avoid wavy/blurry/jagged text. This will automatically render shadows for you as well.
*/
void renderToCanvas(double posX, double posY, const double fontSize, string text, bool rounding = true) {

    // Keep square pixels
    if (rounding) {
        posX = round(posX);
        posY = round(posY);
    }

    // Can't render if no font is selected
    if (currentFont is null) {
        throw new Exception("Razor Font: Tried to render without selecting a font! " ~
            "You must select a font before rendering to canvas!");
    }

    // Can't render to canvas if there IS no canvas
    if (canvasWidth == -1 && canvasHeight == -1) {
        throw new Exception("Razor Font: You have to set the canvas size to render to it!");
    }

    // Store how far the arm has moved to the right
    double typeWriterArmX = 0.0;
    // Store how far the arm has moved down
    double typeWriterArmY = 0.0;

    // Top left of canvas is root position (X: 0, y: 0)
    const positionX = posX - canvasWidth;
    const positionY = posY - canvasHeight;

    // Cache spacing
    const double spacing = currentFont.spacing * fontSize;

    // Cache space (' ') character
    const double spaceCharacterSize = currentFont.spaceCharacterSize * fontSize;

    foreach (key, const(dchar) character; text) {

        // Skip space
        if (character == ' ') {
            typeWriterArmX += spaceCharacterSize;
            continue;
        }
        // Move down 1 space Y and to space 0 X
        if (character == '\n') {
            typeWriterArmY += fontSize;
            typeWriterArmX = 0.0;
            continue;
        }
        
        // Skip unknown character
        if (character !in currentFont.map) {
            continue;
        }

        // Font stores character width in index 9 (8 [0 count])
        double[9] rawData = currentFont.map[character];

        // Keep on the stack
        double[8] textureData = rawData[0..8];
        //Now dispatch into the cache
        for (int i = 0; i < 8; i++) {
            textureCoordinateCache[i + textureCoordinateCount] = textureData[i];
        }

        // This is the width of the character
        // Keep on the stack
        double characterWidth = rawData[8];
        
        // Keep this on the stack
        double[8] rawVertex = RAW_VERTEX;


        // ( 0 x 1 y 2 x 3 y ) <- left side ( 4 x 5 y 6 x 7 y ) <- right side is goal
        // Now apply trimming
        for (int i = 4; i < 8; i += 2) {
            rawVertex[i] = characterWidth;
        }

        // Now scale
        foreach (ref double vertexPosition; rawVertex) {
            vertexPosition *= fontSize;
        }

        // Shifting
        for (int i = 0; i < 8; i += 2) {
            // Now shift right
            rawVertex[i] += typeWriterArmX + positionX;
            // Now shift down
            rawVertex[i + 1] += typeWriterArmY + positionY;
        }

        typeWriterArmX += (characterWidth * fontSize) + spacing;

        // vertexData ~= rawVertex;
        // Now dispatch into the cache
        for (int i = 0; i < 8; i++) {
            vertexCache[i + vertexCount] = rawVertex[i];
        }

        // Keep this on the stack
        int[6] rawIndices = RAW_INDICES;
        foreach (ref value; rawIndices) {
            // Using vertexCount because we're targeting vertex positions
            value += vertexCount / 2;
        }
        // Now dispatch into the cache
        for (int i = 0; i < 6; i++) {
            indicesCache[i + indicesCount] = rawIndices[i];
        }

        // Now hold cursor position (count) in arrays
        vertexCount  += 8;
        textureCoordinateCount += 8;
        indicesCount += 6;
        colorCount += 16;
        // This one is characters literal
        chars++;

        if (vertexCount >= CHARACTER_LIMIT || indicesCount >= CHARACTER_LIMIT) {
            throw new Exception("Character limit is: " ~ to!string(CHARACTER_LIMIT));
        }
    }

    /**
    Because there is no Z buffer in 2d, OpenGL seems to NOT overwrite pixel data of existing
    framebuffer pixels. Since this is my testbed, I must assume that this is how
    Vulkan, Metal, DX, and so-on do this. This is GUARANTEED to not affect software renderers.
    So we have to do the shadowing AFTER the foreground.

    We need to poll, THEN disable the shadow variable because without that it would be
    an infinite recursion, aka a stack overflow.
    */
    const bool shadowsWereEnabled = shadowsEnabled;
    shadowsEnabled = false;
    if (shadowsWereEnabled) {
        const int textLength = getTextRenderableCharsLength(text);
        const int currentIndex = getCurrentCharacterIndex();
        if (shadowColoringEnabled) {
            setColorRange(
                currentIndex,
                currentIndex + textLength,
                shadowColor[0],
                shadowColor[1],
                shadowColor[2],
                shadowColor[3]
            );
        }
        renderToCanvas(posX + (shadowOffsetX * fontSize), posY + (shadowOffsetY * fontSize), fontSize, text, false);

        shadowOffsetX = 0.05;
        shadowOffsetY = 0.05;
    }
    
    // Turn this back on because it can become a confusing nightmare
    shadowColoringEnabled = true;
    // Switch back to black because this also can become a confusing nightmare
    switchShadowColor(0,0,0);
}

/**
Processes your input string, then sends you how long it would be when rendering.
Helpful for repositioning your "cursor" in the texture cache!

Note: This will return cursor position into the beginning index of the background
of the shadowed text if you're using it for subtraction.
*/
int getTextRenderableCharsLength(string input) {
    import std.array;
    return cast(int)input.replace(" ", "").replace("\n", "").length;
}

/**
Processes your input text string with shadows to see how long it would be when rendering.
Helpful for positioning your "cursor" in the texture cache!

Note: This will return cursor position into the beginning index of the foreground
of the shadowed text if you're using it for subtraction.
*/
int getTextRenderableCharsLengthWithShadows(string input) {
    return getTextRenderableCharsLength(input) * 2;
}

/**
Allows you to disable shadow coloring for a teeny tiny bit of performance
when you're doing cool custom shadow coloring!

Important Note: When renderToCanvas() is called, shadow coloring is turned
back on because it can become a confusing nightmare if not done like this.
*/
void disableShadowColoring() {
    shadowColoringEnabled = false;
}

/**
Allows you to manually move around characters.

Note: You can manually move around shadows by getting the
renderable text size before turning on shadows, then offset
your current index into the string by this size.

Note: This is in pixel coordinates.
*/
void moveChar(int index, double posX, double posY) {
    // This gets a bit confusing, so I'm going to write it out verbosely to be able to read/maintain it

    // Move to cursor position in vertexCache
    const int baseIndex = index * 8;

    // Top left
    vertexCache[baseIndex    ] += posX; // X
    vertexCache[baseIndex + 1] -= posY; // Y

    // Bottom left
    vertexCache[baseIndex + 2] += posX; // X
    vertexCache[baseIndex + 3] -= posY; // Y

    // Bottom right
    vertexCache[baseIndex + 4] += posX; // X
    vertexCache[baseIndex + 5] -= posY; // Y

    // Top right
    vertexCache[baseIndex + 6] += posX; // X
    vertexCache[baseIndex + 7] -= posY; // Y
}

/**
Rotate a character around the centerpoint of it's face.

Note: This defaults to radians by default.

Note: If you use moveChar() with this, you MUST do moveChar() first!
*/
void rotateChar(int index, double rotation, bool isDegrees = false) {

    // This is why my doml is required
    import doml.vector_3d;
    import doml.matrix_4d;

    if (isDegrees) {
        immutable radToDegrees = 180.0 / PI;
        rotation *= radToDegrees;
    }

    /**
    This is written out even more verbosely than moveChar()
    so you can see why you must do moveChar() first.
    */

    // Move to cursor position in vertexCache
    const int baseIndex = index * 8;

    // Convert to 3d to suppliment to 4x4 matrix
    Vector3d topLeft     = Vector3d(vertexCache[baseIndex    ], vertexCache[baseIndex + 1], 0);
    Vector3d bottomLeft  = Vector3d(vertexCache[baseIndex + 2], vertexCache[baseIndex + 3], 0);
    Vector3d bottomRight = Vector3d(vertexCache[baseIndex + 4], vertexCache[baseIndex + 5], 0);
    Vector3d topRight    = Vector3d(vertexCache[baseIndex + 6], vertexCache[baseIndex + 7], 0);
    
    Vector3d centerPoint = Vector3d((topLeft.x + topRight.x) / 2.0,  (topLeft.y + bottomLeft.y) / 2.0, 0);

    Vector3d topLeftDiff      = Vector3d(topLeft)    .sub(centerPoint);
    Vector3d bottomLeftDiff   = Vector3d(bottomLeft) .sub(centerPoint);
    Vector3d bottomRighttDiff = Vector3d(bottomRight).sub(centerPoint);
    Vector3d topRighttDiff    = Vector3d(topRight)   .sub(centerPoint);

    // These calculations also store the new data in the variables we created above
    // We must center the coordinates into real coordinates

    Matrix4d().rotate(rotation, 0,0,1).translate(topLeftDiff)     .getTranslation(topLeft);
    Matrix4d().rotate(rotation, 0,0,1).translate(bottomLeftDiff)  .getTranslation(bottomLeft);
    Matrix4d().rotate(rotation, 0,0,1).translate(bottomRighttDiff).getTranslation(bottomRight);
    Matrix4d().rotate(rotation, 0,0,1).translate(topRighttDiff)   .getTranslation(topRight);


    topLeft.x += centerPoint.x;
    topLeft.y += centerPoint.y;

    bottomLeft.x += centerPoint.x;
    bottomLeft.y += centerPoint.y;

    bottomRight.x += centerPoint.x;
    bottomRight.y += centerPoint.y;

    topRight.x += centerPoint.x;
    topRight.y += centerPoint.y;

    vertexCache[baseIndex    ] = topLeft.x;
    vertexCache[baseIndex + 1] = topLeft.y;

    vertexCache[baseIndex + 2] = bottomLeft.x;
    vertexCache[baseIndex + 3] = bottomLeft.y;

    vertexCache[baseIndex + 4] = bottomRight.x;
    vertexCache[baseIndex + 5] = bottomRight.y;

    vertexCache[baseIndex + 6] = topRight.x;
    vertexCache[baseIndex + 7] = topRight.y;
}

//! ============================ END GRAPHICS DISPATCH =============================

//* ========================= BEGIN GRAPHICS ENCODING ==============================

private void encodeGraphics(ref RazorFont fontObject, bool kerning, bool trimming, double spacing, double spaceCharacterSize) {
    
    // Store all this on the stack

    // Total image size
    const double palletWidth = cast(double)fontObject.palletWidth;
    const double palletHeight = cast(double)fontObject.palletHeight;

    // How many characters (width, then height)
    const int rows = fontObject.rows;

    // How wide and tall are the characters in pixels
    const int characterWidth = fontObject.characterWidth;
    const int characterHeight = fontObject.charactertHeight;

    // The border between the characters in pixels
    const int border = fontObject.border;

    // Store font spacing here as it's a one shot operation
    fontObject.spacing = spacing / characterWidth;

    // Store space character width as it's a one shot operation
    fontObject.spaceCharacterSize = spaceCharacterSize / characterWidth;

    // Cache a raw true color image for trimming if requested
    const TrueColorImage tempImageObject = trimming == false ? null : readPng(fontObject.fileLocation).getAsTrueColorImage();

    foreach (size_t i, const(dchar) value; fontObject.rawMap) {

        // Starts off as a normal monospace size
        int thisCharacterWidth = characterWidth;

        // Turn off annoying casting suggestions
        const int index = cast(int) i;

        // Now get where the typewriter is
        const int currentRow = index % rows;
        const int currentColum = index / rows;

        // Now get literal pixel position (top left)
        int intPosX = (characterWidth + border) * currentRow;
        int intPosY = (characterHeight + border) * currentColum;
        
        // left  top,
        // left  bottom,
        // right bottom,
        // right top

        // Now calculate limiters
        // +1 on max because the GL texture stops on the top left of the point in the texture pixel
        int minX = intPosX;
        int maxX = intPosX + characterWidth + 1;

        const int minY = intPosY;
        const int maxY = intPosY + characterHeight + 1;

        // Now trim it if requested
        if (trimming) {

            // Create temp workers
            int newMinX = minX;
            int newMaxX = maxX;

            // Trim left side
            outer1: foreach(x; minX..maxX) {
                newMinX = x;
                foreach (y; minY..maxY) {
                    // This is ubyte (0-255)
                    if (tempImageObject.getPixel(x,y).a > 0) {
                        break outer1;
                    }
                }
            }
            
            // Trim right side
            outer2: foreach_reverse(x; minX..maxX) {
                // +1 because of the reason stated above assigning minX and maxX
                newMaxX = x + 1;
                foreach (y; minY..maxY) {
                    // This is ubyte (0-255)
                    if (tempImageObject.getPixel(x,y).a > 0) {
                        break outer2;
                    }
                }
            }
            
            // I was going to throw a blank space check, but maybe someone has a reason for that

            minX = newMinX;
            maxX = newMaxX;

            thisCharacterWidth = maxX - minX;
            
        }

        // Now shovel it into a raw array so we can easily use it - iPos stands for Integral Positions
        // -1 on maxY because the position was overshot, now we reverse it
        int[] iPos = [
            minX, minY,     // Top left
            minX, maxY - 1, // Bottom left
            maxX, maxY - 1, // Bottom right
            maxX, minY,    // Top right
            
            thisCharacterWidth, // Width
        ];

        // Now calculate REAL graphical texture map
        double[9] glPositions  = [
            iPos[0] / palletWidth, iPos[1] / palletHeight, 
            iPos[2] / palletWidth, iPos[3] / palletHeight,
            iPos[4] / palletWidth, iPos[5] / palletHeight,
            iPos[6] / palletWidth, iPos[7] / palletHeight,

            // Now store char width - Find the new double size by comparing it to original
            // Will simply be 1.0 with monospaced fonts
            cast(double)iPos[8] / cast(double)characterWidth
        ];        

        // Now dump it into the dictionary
        fontObject.map[value] = glPositions;
    }
}





//! ========================= END GRAPICS ENCODING ================================ 


//* ========================== BEGIN JSON DECODING ==================================
// Run through the required data to assemble a font object
private void parseJson(ref RazorFont fontObject, const string jsonLocation) {
    void[] rawData = read(jsonLocation);
    string jsonString = cast(string)rawData;
    JSONValue jsonData = parseJSON(jsonString);

    foreach (string key,JSONValue value; jsonData.objectNoRef) {
        switch(key) {
            case "pallet_width": {
                assert(value.type == JSONType.integer);
                fontObject.palletWidth = cast(int)value.integer;
                break;
            }
            case "pallet_height": {
                assert(value.type == JSONType.integer);
                fontObject.palletHeight = cast(int)value.integer;
                break;
            }
            case "border": {
                assert(value.type == JSONType.integer);
                fontObject.border = cast(int)value.integer;
                break;
            }
            case "rows": {
                assert(value.type == JSONType.integer);
                fontObject.rows = cast(int)value.integer;
                break;
            }
            case "character_width": {
                assert(value.type == JSONType.integer);
                fontObject.characterWidth = cast(int)value.integer;
                break;
            }
            case "charactert_height": {
                assert(value.type == JSONType.integer);
                fontObject.charactertHeight = cast(int)value.integer;
                break;
            }
            case "character_map": {
                assert(value.type == JSONType.string);
                fontObject.rawMap = value.str;
                break;
            }
            default: // Unknown
        }
    }
}


//!============================ END JSON DECODING ==================================

//* ========================== BEGIN API AGNOSTIC CALLS ============================
// Attempts to automate the api RAW call
private void tryCallingRAWApi(string fileLocation) {
    if (renderTargetAPICallRAW is null) {
        return;
    }

    // Use ADR's awesome framework library to convert the png into a raw data stream.
    TrueColorImage tempImageObject = readPng(fileLocation).getAsTrueColorImage();

    const int width = tempImageObject.width();
    const int height = tempImageObject.height();

    renderTargetAPICallRAW(tempImageObject.imageData.bytes, width, height);
}

// Attemps to automate the api String call
private void tryCallingStringApi(string fileLocation) {
    if (renderTargetAPICallString is null) {
        return;
    }
    
    renderTargetAPICallString(fileLocation);
}

//! ======================= END API AGNOSTIC CALLS ================================

//* ===================== BEGIN ETC FUNCTIONS ===============================


// Makes sure there's data where there should be
private void checkFilesExist(string pngLocation, string jsonLocation) {
    if (!exists(pngLocation)) {
        throw new Exception("Razor Font: " ~ pngLocation ~ " does not exist!");
    }

    if (!exists(jsonLocation)) {
        throw new Exception("Razor Font: " ~ jsonLocation ~ " does not exist!");
    }
}

//! ===================== END ETC FUNCTIONS =====================================