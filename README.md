# RazorFont
 A razor sharp font library for D game development.

```
  ____________________________
 |         RAZOR FONT         |
 |____________________________|
  \            /\            /
  /            \/            \
 | The Sharpest Font Library  |
 |   For D Game Development   |
 |____________________________|
 ```

My Discord: https://discord.gg/dRPyvubfyg

RazorFont is pretty simple. You give it a PNG with the font data, then you map the font data with a JSON file.

Fonts are stored in the RazorFont module. There is no need to manually manage fonts yourself.

RazorFont accumulates text via vertex, texture, and indices data. You can render straight to a canvas, then flush it.

RazorFont also has the ability for you to hook your existing rendering engine into it via delegates.

Here are two tutorials tutorial:

[Intro Tutorial](https://github.com/jordan4ibanez/RazorFontExampleProject/blob/main/source/app.d)

[Intermediate Tutorial](https://github.com/jordan4ibanez/RazorFontExampleProjectIntermediate/blob/main/source/app.d)