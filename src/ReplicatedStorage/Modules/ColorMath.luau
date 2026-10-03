--!strict
--!optimize 2
--!native

--[[ ColorMath : Crazyblox 2025
Math on Color3 (add, sub, mul, div, idiv) plus sRGB <-> linear RGB conversion.
Color3 stores 0-1 sRGB floats, which cannot be added or multiplied directly; each
call converts inputs to linear RGB, does the math, and converts back, so it is
convenient rather than fast (avoid heavy loops). Usage: local Color3 = require(path.to.module)
shadows the global and keeps every other Color3 member available.

ColorMath.add / sub / mul / div / idiv( Color3, ...Color3 ): Color3   (sRGB in and out)
ColorMath.sRGB_To_lRGB( ...Color3 ): ...Color3
ColorMath.lRGB_To_sRGB( ...Color3 ): ...Color3
]]

local ColorMath = {
	--Adds given Color3's in order
	add = function( Start: Color3, ...: Color3 ): Color3
		--Start with initial color
		local C: vector = vector.create(
			Start.R <= 0.04045 and Start.R * 0.07739938080495357 or ( ( Start.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.G <= 0.04045 and Start.G * 0.07739938080495357 or ( ( Start.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.B <= 0.04045 and Start.B * 0.07739938080495357 or ( ( Start.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
		)
		--Iterate through remainder of colors
		for _, Color: Color3 in {...} do 
			C += vector.create(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			)
		end
		return Color3.new(
			C.x <= 0.0031308 and C.x * 12.92 or 1.055 * ( C.x ^ 0.4166666666666667 ) - 0.055,
			C.y <= 0.0031308 and C.y * 12.92 or 1.055 * ( C.y ^ 0.4166666666666667 ) - 0.055,
			C.z <= 0.0031308 and C.z * 12.92 or 1.055 * ( C.z ^ 0.4166666666666667 ) - 0.055
		)
	end,
	
	--Subtracts given Color3's in order
	sub = function( Start: Color3, ...: Color3 ): Color3
		--Start with initial color
		local C: vector = vector.create(
			Start.R <= 0.04045 and Start.R * 0.07739938080495357 or ( ( Start.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.G <= 0.04045 and Start.G * 0.07739938080495357 or ( ( Start.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.B <= 0.04045 and Start.B * 0.07739938080495357 or ( ( Start.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
		)
		--Iterate through remainder of colors
		for _, Color: Color3 in {...} do
			C -= vector.create(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			)
		end
		return Color3.new(
			C.x <= 0.0031308 and C.x * 12.92 or 1.055 * ( C.x ^ 0.4166666666666667 ) - 0.055,
			C.y <= 0.0031308 and C.y * 12.92 or 1.055 * ( C.y ^ 0.4166666666666667 ) - 0.055,
			C.z <= 0.0031308 and C.z * 12.92 or 1.055 * ( C.z ^ 0.4166666666666667 ) - 0.055
		)
	end,
	
	--Multiplies given Color3's in order
	mul = function( Start: Color3, ...: Color3 ): Color3
		--Start with initial color
		local C: vector = vector.create(
			Start.R <= 0.04045 and Start.R * 0.07739938080495357 or ( ( Start.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.G <= 0.04045 and Start.G * 0.07739938080495357 or ( ( Start.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.B <= 0.04045 and Start.B * 0.07739938080495357 or ( ( Start.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
		)
		--Iterate through remainder of colors
		for _, Color: Color3 in {...} do
			C *= vector.create(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			)
		end
		return Color3.new(
			C.x <= 0.0031308 and C.x * 12.92 or 1.055 * ( C.x ^ 0.4166666666666667 ) - 0.055,
			C.y <= 0.0031308 and C.y * 12.92 or 1.055 * ( C.y ^ 0.4166666666666667 ) - 0.055,
			C.z <= 0.0031308 and C.z * 12.92 or 1.055 * ( C.z ^ 0.4166666666666667 ) - 0.055
		)
	end,
	
	--Divides given Color3's in order
	div = function( Start: Color3, ...: Color3 ): Color3
		--Start with initial color
		local C: vector = vector.create(
			Start.R <= 0.04045 and Start.R * 0.07739938080495357 or ( ( Start.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.G <= 0.04045 and Start.G * 0.07739938080495357 or ( ( Start.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.B <= 0.04045 and Start.B * 0.07739938080495357 or ( ( Start.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
		)
		--Iterate through remainder of colors
		for _, Color: Color3 in {...} do
			C /= vector.create(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			)
		end
		return Color3.new(
			C.x <= 0.0031308 and C.x * 12.92 or 1.055 * ( C.x ^ 0.4166666666666667 ) - 0.055,
			C.y <= 0.0031308 and C.y * 12.92 or 1.055 * ( C.y ^ 0.4166666666666667 ) - 0.055,
			C.z <= 0.0031308 and C.z * 12.92 or 1.055 * ( C.z ^ 0.4166666666666667 ) - 0.055
		)
	end,
	
	idiv = function( Start: Color3, ...: Color3 ): Color3
		local C: vector = vector.create(
			Start.R <= 0.04045 and Start.R * 0.07739938080495357 or ( ( Start.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.G <= 0.04045 and Start.G * 0.07739938080495357 or ( ( Start.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
			Start.B <= 0.04045 and Start.B * 0.07739938080495357 or ( ( Start.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
		)
		for _, Color: Color3 in {...} do
			C //= vector.create(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			)
		end
		return Color3.new(
			C.x <= 0.0031308 and C.x * 12.92 or 1.055 * ( C.x ^ 0.4166666666666667 ) - 0.055,
			C.y <= 0.0031308 and C.y * 12.92 or 1.055 * ( C.y ^ 0.4166666666666667 ) - 0.055,
			C.z <= 0.0031308 and C.z * 12.92 or 1.055 * ( C.z ^ 0.4166666666666667 ) - 0.055
		)
	end,
	
	sRGB_To_lRGB = function( ...: Color3 ): ...Color3
		local C: {Color3} = {}
		for _, Color: Color3 in {...} do
			table.insert( C, Color3.new(
				Color.R <= 0.04045 and Color.R * 0.07739938080495357 or ( ( Color.R + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.G <= 0.04045 and Color.G * 0.07739938080495357 or ( ( Color.G + 0.055 ) * 0.9478672985781991 ) ^ 2.4,
				Color.B <= 0.04045 and Color.B * 0.07739938080495357 or ( ( Color.B + 0.055 ) * 0.9478672985781991 ) ^ 2.4
			) )
		end
		return table.unpack( C )
	end,
	
	lRGB_To_sRGB = function( ...: Color3 ): ...Color3
		local C: {Color3} = {}
		for _, Color: Color3 in {...} do
			table.insert( C, Color3.new(
				Color.R <= 0.0031308 and Color.R * 12.92 or 1.055 * ( Color.R ^ 0.4166666666666667 ) - 0.055,
				Color.G <= 0.0031308 and Color.G * 12.92 or 1.055 * ( Color.G ^ 0.4166666666666667 ) - 0.055,
				Color.B <= 0.0031308 and Color.B * 12.92 or 1.055 * ( Color.B ^ 0.4166666666666667 ) - 0.055
				) )
		end
		return table.unpack( C )
	end
}
for name, method in Color3 do
	if not ColorMath[ name ] then
		ColorMath[ name ] = method
	end
end
return table.freeze( ColorMath )