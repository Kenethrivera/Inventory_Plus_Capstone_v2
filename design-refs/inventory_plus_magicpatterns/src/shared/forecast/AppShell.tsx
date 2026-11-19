import React, { useState } from 'react'
import { AnimatePresence, motion } from 'framer-motion'
import {
  LayoutDashboard,
  ShoppingCart,
  Package,
  TrendingUp,
  Truck,
  BarChart3,
  Settings,
  Menu,
  X,
} from 'lucide-react'

const NAV = [
  { label: 'Dashboard', icon: LayoutDashboard },
  { label: 'Point of Sale', icon: ShoppingCart },
  { label: 'Inventory', icon: Package },
  { label: 'Forecasting', icon: TrendingUp, active: true },
  { label: 'Suppliers', icon: Truck },
  { label: 'Reports', icon: BarChart3 },
]

export function AppShell({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = useState(false)
  return (
    <div className="flex h-screen bg-page text-ink">
      <aside className="hidden w-60 shrink-0 border-r border-line bg-sidebar lg:flex lg:flex-col">
        <SidebarContent />
      </aside>

      <AnimatePresence>
        {open && (
          <>
            <motion.div
              className="fixed inset-0 z-30 bg-ink/30 lg:hidden"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.2, ease: 'easeOut' }}
              onClick={() => setOpen(false)}
            />
            <motion.aside
              className="fixed inset-y-0 left-0 z-40 flex w-64 flex-col bg-sidebar shadow-xl lg:hidden"
              initial={{ x: -280 }}
              animate={{ x: 0 }}
              exit={{ x: -280 }}
              transition={{ duration: 0.25, ease: [0.23, 1, 0.32, 1] }}
            >
              <button
                onClick={() => setOpen(false)}
                className="absolute right-3 top-4 rounded-md p-1.5 text-muted hover:bg-page"
                aria-label="Close menu"
              >
                <X className="h-5 w-5" />
              </button>
              <SidebarContent />
            </motion.aside>
          </>
        )}
      </AnimatePresence>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center gap-3 border-b border-line bg-surface px-4 py-3 lg:hidden">
          <button onClick={() => setOpen(true)} className="rounded-md p-1.5 text-body hover:bg-page" aria-label="Open menu">
            <Menu className="h-5 w-5" />
          </button>
          <Logo />
        </header>
        <main className="min-w-0 flex-1 overflow-y-auto">{children}</main>
      </div>
    </div>
  )
}

function SidebarContent() {
  return (
    <>
      <div className="px-5 pb-6 pt-5">
        <Logo />
      </div>
      <nav className="flex-1 space-y-0.5 px-3">
        {NAV.map((item) => (
          <a
            key={item.label}
            href="#"
            onClick={(e) => e.preventDefault()}
            className={`flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors duration-150 ${
              item.active ? 'bg-accent-soft text-accent' : 'text-body hover:bg-page hover:text-ink'
            }`}
          >
            <item.icon className="h-[18px] w-[18px]" strokeWidth={item.active ? 2.2 : 1.8} />
            {item.label}
          </a>
        ))}
      </nav>
      <div className="border-t border-line px-3 py-3">
        <a
          href="#"
          onClick={(e) => e.preventDefault()}
          className="flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium text-body transition-colors duration-150 hover:bg-page"
        >
          <Settings className="h-[18px] w-[18px]" strokeWidth={1.8} />
          Settings
        </a>
        <div className="mt-2 flex items-center gap-3 px-3 py-2">
          <div className="flex h-8 w-8 items-center justify-center rounded-full bg-page text-xs font-semibold text-body">DM</div>
          <div className="min-w-0">
            <p className="truncate text-sm font-medium text-ink">Dana Mercer</p>
            <p className="truncate text-xs text-muted">Main St. Hardware</p>
          </div>
        </div>
      </div>
    </>
  )
}

function Logo() {
  return (
    <div className="flex items-center gap-2">
      <div className="flex h-7 w-7 items-center justify-center rounded-md bg-accent text-sm font-bold text-white">I+</div>
      <span className="text-[15px] font-semibold tracking-tight text-ink">Inventory Plus</span>
    </div>
  )
}
