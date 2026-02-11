shader_type canvas_item;

void fragment() {
	vec4 src = texture(TEXTURE, UV);
	COLOR = vec4(1.0 - src.rgb, src.a); // invert colors
}
