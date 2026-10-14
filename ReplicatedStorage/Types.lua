-- script hijo de Gerstner


export type VertexKey = {
	VertexId: number,
	ColorId: number,
	UVId: number,

	UV: Vector2,
	Position: Vector3,

	Lerping: boolean,
	CurrentFrame: number,
	
	GoalPosition: Vector3,
	LastPosition: Vector3,

	AlphaTransparency: number,
	CurrentColor: Color3,
	QUALITY_LEVEL: number,
}
export type ChunkKey = {
	Rendering: boolean,
	ISLAND: {number | any} | nil,
	ZONE: {number | any} | nil,
}

export type Computations = { {Vector3 | Color3 | number | Vector2 | nil} }

return {}