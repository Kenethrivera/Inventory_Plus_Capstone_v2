import React, { useState } from 'react'

import Overview from '../n6bbyevvKwBgWSQSR7Vw3z.frame'
import ProductForecast from '../6EP5TnPFF4K5yxYMkaYTzE.frame'
import TrackingAccuracy from '../1H3Q4oMStkkZaY7toRpXTY.frame'
import Research from '../au5ToZiJStKRm5mKSASktB.frame'

const OVERVIEW = 'n6bbyevvKwBgWSQSR7Vw3z'
const PRODUCT = '6EP5TnPFF4K5yxYMkaYTzE'
const ACCURACY = '1H3Q4oMStkkZaY7toRpXTY'
const RESEARCH = 'au5ToZiJStKRm5mKSASktB'

const TAB_TO_FRAME: Record<string, string> = {
  overview: OVERVIEW,
  product: PRODUCT,
  tracking: ACCURACY,
  research: RESEARCH,
}

/** The size every frame draws at, unless one exports its own. */
export const viewport = 'web'

export const args = {
  model: 'blend',
  horizon: '28',
}

export const argTypes = {
  model: { control: 'select', options: ['blend', 'lightgbm', 'mean28', 'seasonal'] },
  horizon: { control: 'radio', options: ['7', '28'] },
}

type Props = Partial<typeof args> & { start?: string }

export default function ForecastingOverview(props: Props) {
  const { model: initialModel, horizon: initialHorizon, start } = { ...args, ...props }
  const [step, setStep] = useState(() => start ?? OVERVIEW)
  const [model, setModel] = useState(initialModel)
  const [horizon, setHorizon] = useState(initialHorizon)
  const [productId, setProductId] = useState('p1')

  React.useEffect(() => setModel(initialModel), [initialModel])
  React.useEffect(() => setHorizon(initialHorizon), [initialHorizon])

  const onTabChange = (t: string) => setStep(TAB_TO_FRAME[t] ?? OVERVIEW)
  const shared = { model, horizon, onModelChange: setModel, onHorizonChange: setHorizon, onTabChange }

  if (step === ACCURACY) return <TrackingAccuracy onTabChange={onTabChange} />
  if (step === RESEARCH) return <Research onTabChange={onTabChange} />

  if (step === PRODUCT) {
    return (
      <ProductForecast
        {...shared}
        productId={productId}
        onProductChange={setProductId}
        onViewAccuracy={() => setStep(ACCURACY)}
      />
    )
  }

  return (
    <Overview
      {...shared}
      onViewAccuracy={() => setStep(ACCURACY)}
      onOpenProduct={(id) => {
        setProductId(id)
        setStep(PRODUCT)
      }}
    />
  )
}
