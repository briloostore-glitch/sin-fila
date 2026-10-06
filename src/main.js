import { detectCity, listActiveCities } from './location.js'

const root = document.querySelector('#app') ?? document.body

root.innerHTML = `
  <main>
    <h1>Sin Fila</h1>
    <p id="status">Cargando ciudades...</p>
    <button id="btn-detect" type="button">Detectar mi ciudad</button>
    <select id="city-select"></select>
  </main>
`

const statusEl = document.querySelector('#status')
const selectEl = document.querySelector('#city-select')
const detectBtn = document.querySelector('#btn-detect')

async function loadCities() {
  try {
    const cities = await listActiveCities()
    selectEl.innerHTML = ''
    for (const c of cities) {
      const opt = document.createElement('option')
      opt.value = c.id
      opt.textContent = c.name
      selectEl.appendChild(opt)
    }
    statusEl.textContent = cities.length
      ? 'Elige una ciudad o permite la ubicacion.'
      : 'Aun no hay ciudades activas.'
  } catch (err) {
    statusEl.textContent = 'Error cargando ciudades: ' + err.message
  }
}

detectBtn.addEventListener('click', async () => {
  statusEl.textContent = 'Detectando ubicacion...'
  try {
    const { city } = await detectCity()
    if (city) {
      selectEl.value = city.id
      statusEl.textContent = 'Ciudad detectada: ' + city.name
    } else {
      statusEl.textContent = 'Tu ubicacion esta fuera de las ciudades activas. Elige una de la lista.'
    }
  } catch (err) {
    statusEl.textContent = 'No se pudo obtener la ubicacion. Elige una ciudad de la lista.'
  }
})

loadCities()