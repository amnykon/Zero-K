#version 420
#extension GL_ARB_uniform_buffer_object : require
#extension GL_ARB_shading_language_420pack: require

// This file is going to be licensed under some sort of GPL-compatible license, but authors are dragging
// their feet. Avoid copying for now (unless this header rots for years on end), and check back later.
// See https://github.com/ZeroK-RTS/Zero-K/issues/5328

//__ENGINEUNIFORMBUFFERDEFS__
//__DEFINES__

#line 30000
in DataGS {
	vec4 g_color;
	vec4 g_uv;
};

uniform sampler2D healthbartexture;
out vec4 fragColor;

void main(void)
{
	vec4 texcolor = vec4(1.0);
	texcolor = texture(healthbartexture, g_uv.xy);
	texcolor.a *= g_color.a;
	fragColor.rgba = mix(g_color, texcolor, g_uv.z);
	//fragColor.rgba += vec4(0.25);
	//fragColor.a += 0.5;
	//fragColor.a = 1.0;
	if (fragColor.a < 0.05) discard;
}
