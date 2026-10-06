import {
  NeutralToneMapping, DataTexture, DirectionalLight, EquirectangularReflectionMapping,
  AmbientLight, Group, Mesh, MeshPhysicalMaterial, OrthographicCamera, PerspectiveCamera, PMREMGenerator, RGBAFormat,
  Scene, SRGBColorSpace, Texture, WebGLRenderer, type Material,
} from 'three'
import { USDLoader } from 'three/addons/loaders/USDLoader.js'
import cartridgeUrl from '../assets/models/LivesFilm.usdz?url'
import loupeUrl from '../assets/models/PreviewLoupe.usdz?url'
import { normalizeFilmModel } from './filmObjectGeometry'
import { filmModelArchiveForLoader } from './filmModelArchive'

export type FilmObjectKind = 'cartridge' | 'loupe'
export interface FilmObjectPose { reveal: number; turn: number; tiltX: number; tiltY: number }

const releaseModel = (model: Group) => {
  const textures = new Set<Texture>()
  const materials = new Set<Material>()
  model.traverse((object) => {
    if (!(object instanceof Mesh)) return
    object.geometry.dispose()
    for (const material of Array.isArray(object.material) ? object.material : [object.material]) {
      materials.add(material)
      for (const value of Object.values(material)) if (value instanceof Texture) textures.add(value)
    }
  })
  materials.forEach((material) => material.dispose())
  textures.forEach((texture) => {
    const bitmap = texture.image as { close?: () => void } | undefined
    if (typeof bitmap?.close === 'function') bitmap.close()
    texture.dispose()
  })
}

// Loaded lazily. Both objects keep their scene and redraw only when the pose changes.
export async function createFilmObjectRenderer(canvas: HTMLCanvasElement, kind: FilmObjectKind, signal: AbortSignal) {
  const renderer = new WebGLRenderer({ canvas, alpha: true, antialias: true, powerPreference: 'low-power' })
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
  renderer.outputColorSpace = SRGBColorSpace
  renderer.toneMapping = NeutralToneMapping
  renderer.toneMappingExposure = 1
  const scene = new Scene()
  const camera = kind === 'cartridge' ? new OrthographicCamera(-.58, .58, .58, -.58, .01, 20) : new PerspectiveCamera(30, 1, .01, 20)
  let model: Group | undefined
  let environment: ReturnType<PMREMGenerator['fromEquirectangular']> | undefined

  const dispose = () => {
    if (model) releaseModel(model)
    environment?.dispose()
    renderer.dispose()
    renderer.forceContextLoss()
  }

  try {
    const response = await fetch(kind === 'cartridge' ? cartridgeUrl : loupeUrl, { signal })
    if (!response.ok) throw new Error('Film model unavailable')
    const buffer = await response.arrayBuffer()
    await new Promise<void>((resolve, reject) => {
      model = new USDLoader().parse(filmModelArchiveForLoader(buffer), '', () => resolve(), reject)
    })
    signal.throwIfAborted()
    if (!model) throw new Error('Film model empty')
    normalizeFilmModel(model)
    model.traverse((node) => {
      if (!(node instanceof Mesh)) return
      if (kind === 'loupe' && ['Transparent_Flared_Stand', 'Polished_Bottom_Glass_Rim'].includes(node.name)) node.visible = false
      for (const material of Array.isArray(node.material) ? node.material : [node.material]) {
        if (!(material instanceof MeshPhysicalMaterial)) continue
        if (kind === 'cartridge') {
          if (node.name.includes('Barrel')) material.roughness = .24
          if (node.name.includes('Flange')) material.roughness = .20
          // Mobile's display uses charcoal paint while retaining the original gold label.
          material.onBeforeCompile = (shader) => {
            shader.fragmentShader = shader.fragmentShader.replace('#include <map_fragment>', `#include <map_fragment>
              float paintMaximum = max(diffuseColor.r, max(diffuseColor.g, diffuseColor.b));
              if (paintMaximum < 0.2 && diffuseColor.g > diffuseColor.r * 1.14 && diffuseColor.g > diffuseColor.b * 1.08) {
                float charcoal = dot(diffuseColor.rgb, vec3(0.2126, 0.7152, 0.0722));
                diffuseColor.rgb = vec3(charcoal);
              }`)
          }
          material.customProgramCacheKey = () => 'lives-film-charcoal-v1'
        } else {
          if (node.name === 'Rounded_Black_Barrel') material.roughness = .36
          if (material.transparent) material.depthWrite = false
        }
      }
    })
    const object = new Group()
    object.add(model)
    scene.add(object)
    scene.add(new AmbientLight(0xffffff, (kind === 'cartridge' ? .55 : .38) * Math.PI))
    const key = new DirectionalLight(0xffffff, (kind === 'cartridge' ? .8 : .95) * Math.PI)
    if (kind === 'cartridge') key.position.set(1, 1, 1)
    else key.position.set(-.8, 1.3, 1.4)
    scene.add(key)
    const rim = new DirectionalLight(0xdbe8ff, .32 * Math.PI)
    rim.position.set(1, .55, .75)
    scene.add(rim)

    const stops = [[0, .24], [.19, .88], [.34, .35], [.69, .70], [1, .18]]
    const pixels = new Uint8Array(256 * 128 * 4)
    for (let y = 0; y < 128; y++) for (let x = 0; x < 256; x++) {
      const position = y / 127
      const index = Math.max(1, stops.findIndex(([location]) => location >= position))
      const [from, a] = stops[index - 1]
      const [to, b] = stops[index]
      const light = Math.round((a + (b - a) * (position - from) / (to - from)) * 255)
      const offset = (y * 256 + x) * 4
      pixels.set([light, light, light, 255], offset)
    }
    const studio = new DataTexture(pixels, 256, 128, RGBAFormat)
    studio.colorSpace = SRGBColorSpace
    studio.mapping = EquirectangularReflectionMapping
    studio.needsUpdate = true
    const generator = new PMREMGenerator(renderer)
    environment = generator.fromEquirectangular(studio)
    scene.environment = environment.texture
    scene.environmentIntensity = kind === 'cartridge' ? .42 : .6
    studio.dispose()
    generator.dispose()

    let previousWidth = 0
    let previousHeight = 0
    const render = (pose: FilmObjectPose) => {
      if (signal.aborted) return
      const width = Math.max(1, canvas.clientWidth)
      const height = Math.max(1, canvas.clientHeight)
      if (width !== previousWidth || height !== previousHeight) {
        renderer.setSize(width, height, false)
        previousWidth = width
        previousHeight = height
      }
      if (camera instanceof OrthographicCamera) {
        camera.left = -.58 * width / height
        camera.right = .58 * width / height
        camera.position.set(0, .20, 1.7)
      } else {
        camera.aspect = width / height
        const lift = .58 + 1.72 * pose.reveal
        const depth = 1.7 - 1.52 * pose.reveal
        camera.position.set(0, lift, depth)
        camera.fov = 2 * Math.atan((.62 - .20 * pose.reveal) / Math.hypot(lift, depth)) * 180 / Math.PI
      }
      const glassBead = model?.getObjectByName('Hidden_Upper_Glass_Bead')
      if (glassBead instanceof Mesh) for (const material of Array.isArray(glassBead.material) ? glassBead.material : [glassBead.material]) {
        material.transparent = true
        material.opacity = .025 * (1 - Math.min(1, pose.reveal / .55))
        material.depthWrite = false
      }
      camera.lookAt(0, 0, 0)
      camera.updateProjectionMatrix()
      object.rotation.set(pose.tiltX, pose.turn + pose.tiltY, 0)
      renderer.render(scene, camera)
    }
    return { render, dispose }
  } catch (error) {
    dispose()
    throw error
  }
}
