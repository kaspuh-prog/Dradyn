shader_type canvas_item;

uniform vec4 u_inner_outline_color : source_color = vec4(0.05, 0.05, 0.08, 1.0);
uniform float u_inner_outline_alpha : hint_range(0.0, 1.0) = 0.85;
uniform float u_outline_px : hint_range(1.0, 3.0) = 1.0;

void fragment() {
	vec4 src = texture(TEXTURE, UV);
	vec2 px = TEXTURE_PIXEL_SIZE * u_outline_px;

	float a = src.a;

	// Sample neighbors
	float n0 = texture(TEXTURE, UV + vec2( px.x, 0.0)).a;
	float n1 = texture(TEXTURE, UV + vec2(-px.x, 0.0)).a;
	float n2 = texture(TEXTURE, UV + vec2(0.0,  px.y)).a;
	float n3 = texture(TEXTURE, UV + vec2(0.0, -px.y)).a;

	float n4 = texture(TEXTURE, UV + vec2( px.x,  px.y)).a;
	float n5 = texture(TEXTURE, UV + vec2( px.x, -px.y)).a;
	float n6 = texture(TEXTURE, UV + vec2(-px.x,  px.y)).a;
	float n7 = texture(TEXTURE, UV + vec2(-px.x, -px.y)).a;

	float neighbor_min = min(min(min(n0, n1), min(n2, n3)), min(min(n4, n5), min(n6, n7)));

	// Visible pixels only: mask out fully transparent pixels
	float visible = step(0.01, a);

	// If any neighbor is transparent, this pixel is on the edge (inner outline)
	float edge = (1.0 - step(0.01, neighbor_min)) * visible;

	vec3 rgb = src.rgb;
	rgb = mix(rgb, u_inner_outline_color.rgb, edge * u_inner_outline_alpha);

	COLOR = vec4(rgb, a);
}
